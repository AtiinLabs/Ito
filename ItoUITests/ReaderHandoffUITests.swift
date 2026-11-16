import Foundation
import XCTest

/// The image/text reader handoff, on screen. The handoff fixture serves one manga whose Chapter 1 is images,
/// Chapter 2 text, Chapter 3 images and Chapter 4 text that always fails to load, all from local data, so
/// every neighbor belongs to the other reader. Waits are on element existence, never on time.
@MainActor
final class ReaderHandoffUITests: XCTestCase {
    private static let fixtureSourceName = "Reader Handoff Fixture"
    private static let sourceSearchPrompt = "Search source..."
    private static let sourceSearchText = "Reader Handoff"
    private static let mangaTitle = "Reader Handoff Manga"
    private static let textBody = "Handoff text chapter two first paragraph."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Chapter 1 (images) to Chapter 2 (text) with the Next Chapter control, then to Chapter 3 (images).
    func testNextChapterMovesFromImagesToTextAndFromTextBackToImages() throws {
        let app = try openFixture()
        openSeries(app)
        require(imagePage(app, 1), in: app, "Chapter 1 image page 1")
        expectAbsent(text(app, Self.textBody), in: app, "Chapter 2 text before Next Chapter")
        attach(app, name: "1 Source: Chapter 1 image page before Next Chapter")

        app.buttons["Next Chapter"].tap()
        require(text(app, Self.textBody), in: app, "Chapter 2 text body in the text reader")
        requireGone(imagePage(app, 1), in: app, "Chapter 1 image page after the handoff")
        attach(app, name: "2 Destination: Chapter 2 text reader after images to text")

        app.buttons["Next Chapter"].tap()
        require(imagePage(app, 1), in: app, "Chapter 3 image page 1 in the page reader")
        requireGone(text(app, Self.textBody), in: app, "Chapter 2 text after the handoff back to images")
        attach(app, name: "3 Destination: Chapter 3 page reader after text to images")

        // One reader screen throughout: closing once returns to the series, not to another reader.
        app.buttons["Close Reader"].tap()
        require(app.buttons["Resume"], in: app, "Series screen after one Close")
    }

    /// Paging past the last image of Chapter 1 continues in the text reader, and the first page is on screen.
    func testPagedEdgeOnTheLastImageOpensTheTextReader() throws {
        let app = try openFixture()
        openSeries(app)
        require(imagePage(app, 1), in: app, "Chapter 1 image page 1")
        let nextPage = app.buttons["Next Page"]
        require(nextPage, in: app, "Next Page control")
        nextPage.tap()
        require(imagePage(app, 2), in: app, "Chapter 1 image page 2")
        attach(app, name: "4 Source: Chapter 1 last page before the paged edge")

        // The fixture's viewer reads right to left: forward is a swipe to the right, past the last page.
        app.swipeRight()
        require(text(app, Self.textBody), in: app, "Chapter 2 text body after the paged edge")
        requireGone(imagePage(app, 2), in: app, "Chapter 1 last page after the paged edge")
        attach(app, name: "5 Destination: Chapter 2 text reader after the paged edge")
    }

    /// A destination that cannot be loaded leaves the source on screen at the same page, and Cancel keeps it.
    func testAFailingDestinationKeepsTheSourcePageAndCancelLeavesItThere() throws {
        let app = try openFixture()
        openSeries(app)
        require(imagePage(app, 1), in: app, "Chapter 1 image page 1")
        app.buttons["Next Chapter"].tap()
        require(text(app, Self.textBody), in: app, "Chapter 2 text body")
        app.buttons["Next Chapter"].tap()
        require(imagePage(app, 1), in: app, "Chapter 3 image page 1")
        let nextPage = app.buttons["Next Page"]
        require(nextPage, in: app, "Next Page control")
        nextPage.tap()
        require(imagePage(app, 2), in: app, "Chapter 3 image page 2")

        // Chapter 4 is text that fails to load: the source stays, with a notice that can be cancelled.
        app.buttons["Next Chapter"].tap()
        let failure = app.staticTexts["Couldn't open the next chapter."]
        require(failure, in: app, "failure notice for Chapter 4")
        XCTAssertTrue(imagePage(app, 2).exists, "The source page stays on screen while the handoff has failed")
        XCTAssertTrue(app.staticTexts["Page 2 of 2"].exists, "The source reader's page counter stays")
        attach(app, name: "6 Failure: Chapter 3 page 2 stays with the notice")

        app.buttons["Cancel"].tap()
        requireGone(failure, in: app, "failure notice after Cancel")
        require(imagePage(app, 2), in: app, "Chapter 3 page 2 after Cancel")
        attach(app, name: "7 Cancel: Chapter 3 stays on the same page")
    }

    // MARK: - Fixture and navigation

    private func openFixture() throws -> XCUIApplication {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "reader-handoff", withExtension: "ito", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "reader-handoff", withExtension: "ito")
        )
        let app = XCUIApplication.english(arguments: ["--ui-test-reset-storage"])
        app.launchEnvironment["ITO_UI_TEST_PLUGIN_BASE64"] = try Data(contentsOf: url).base64EncodedString()
        app.launch()
        let browse = app.tabBars.buttons["Browse"]
        require(browse, in: app, "Browse tab")
        browse.tap()
        let source = app.staticTexts[Self.fixtureSourceName]
        require(source, in: app, "\(Self.fixtureSourceName) source row")
        source.tap()
        let search = app.searchFields[Self.sourceSearchPrompt]
        require(search, in: app, "source search field")
        search.tap()
        search.typeText(Self.sourceSearchText)
        return app
    }

    private func openSeries(_ app: XCUIApplication) {
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.mangaTitle))
            .firstMatch
        require(entry, in: app, "search result \(Self.mangaTitle)")
        entry.tap()
        let start = app.buttons["Start"]
        require(start, in: app, "Start button")
        start.tap()
    }

    // MARK: - Queries and waits

    /// An image page of the page reader: its accessibility label is "Page N".
    private func imagePage(_ app: XCUIApplication, _ number: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Page \(number)"))
            .firstMatch
    }

    /// A text element whose label or value holds `value`.
    private func text(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value))
            .firstMatch
    }

    private func require(
        _ element: XCUIElement,
        in app: XCUIApplication,
        _ what: String,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.waitForExistence(timeout: timeout) else {
            failWithHierarchy(app, "\(what) did not appear within \(Int(timeout))s", file: file, line: line)
            return
        }
    }

    private func requireGone(
        _ element: XCUIElement,
        in app: XCUIApplication,
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.waitForNonExistence(timeout: timeout) else {
            failWithHierarchy(app, "\(what) did not disappear within \(Int(timeout))s", file: file, line: line)
            return
        }
    }

    private func expectAbsent(
        _ element: XCUIElement,
        in app: XCUIApplication,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element.exists {
            failWithHierarchy(app, "\(what) is present", file: file, line: line)
        }
    }

    /// Attaches the app's accessibility hierarchy to the test result, then fails the test.
    private func failWithHierarchy(
        _ app: XCUIApplication,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Hierarchy: \(message)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail(message, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
