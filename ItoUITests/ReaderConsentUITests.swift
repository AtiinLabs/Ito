import Foundation
import XCTest

/// The "Switch groups?" alert that guards another translation group's upload. The reader-consent
/// fixture serves two uploads of each series: Chapter 1 from Group A and Chapter 2 from Group B.
/// Every setting is turned on through the reader's own Settings UI.
@MainActor
final class ReaderConsentUITests: XCTestCase {
    private static let fixtureSourceName = "Reader Consent Fixture"
    private static let sourceSearchPrompt = "Search source..."
    private static let sourceSearchText = "Reader Consent"
    private static let mangaTitle = "Reader Consent Manga"
    private static let novelTitle = "Reader Consent Novel"
    private static let askToggleLabel = "Ask before switching groups"
    private static let alertTitle = "Switch groups?"
    private static let openUploadLabel = "Open This Upload"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMangaCancelKeepsChapterAAndOpenThisUploadLoadsChapterB() throws {
        let app = try openFixture()
        openSeries(app, title: Self.mangaTitle)
        require(text(app, "Reader fixture manga A page 1"), in: app, "Chapter 1 page 1 of the manga")
        turnOnAskBeforeSwitchingInMangaReader(app)

        app.buttons["Next Chapter"].tap()
        let alert = app.alerts[Self.alertTitle]
        require(alert, in: app, "switch groups alert")
        requireAlertMessage(alert, in: app, contains: "Group B")
        attach(app, name: "Manga switch groups alert before Chapter 2")

        alert.buttons["Cancel"].tap()
        requireGone(alert, in: app, "switch groups alert after Cancel")
        require(text(app, "Reader fixture manga A page 1"), in: app, "Chapter 1 page 1 after Cancel")
        expectAbsent(text(app, "Reader fixture manga B"), in: app, "Chapter 2 text after Cancel")
        attach(app, name: "Manga cancel keeps Chapter 1 from Group A")

        app.buttons["Next Chapter"].tap()
        require(alert, in: app, "switch groups alert on second Next Chapter")
        alert.buttons[Self.openUploadLabel].tap()
        require(text(app, "Reader fixture manga B"), in: app, "Chapter 2 text after Open This Upload")
        requireGone(text(app, "Reader fixture manga A page 1"), in: app, "Chapter 1 text after Open This Upload")
        attach(app, name: "Manga Open This Upload loads Chapter 2 from Group B")
    }

    func testNovelCancelKeepsChapterAAndOpenThisUploadLoadsChapterB() throws {
        let app = try openFixture()
        openSeries(app, title: Self.novelTitle)
        require(text(app, "Reader fixture novel A"), in: app, "Chapter 1 text of the novel")
        turnOnAskBeforeSwitchingInNovelReader(app)

        app.buttons["Next Chapter"].tap()
        let alert = app.alerts[Self.alertTitle]
        require(alert, in: app, "switch groups alert")
        requireAlertMessage(alert, in: app, contains: "Group B")
        attach(app, name: "Novel switch groups alert before Chapter 2")

        alert.buttons["Cancel"].tap()
        requireGone(alert, in: app, "switch groups alert after Cancel")
        require(text(app, "Reader fixture novel A"), in: app, "Chapter 1 text after Cancel")
        expectAbsent(text(app, "Reader fixture novel B"), in: app, "Chapter 2 text after Cancel")
        attach(app, name: "Novel cancel keeps Chapter 1 from Group A")

        app.buttons["Next Chapter"].tap()
        require(alert, in: app, "switch groups alert on second Next Chapter")
        alert.buttons[Self.openUploadLabel].tap()
        require(text(app, "Reader fixture novel B"), in: app, "Chapter 2 text after Open This Upload")
        requireGone(text(app, "Reader fixture novel A"), in: app, "Chapter 1 text after Open This Upload")
        attach(app, name: "Novel Open This Upload loads Chapter 2 from Group B")
    }

    func testMangaDefaultOffNextChapterOpensChapterBWithoutAlert() throws {
        let app = try openFixture()
        openSeries(app, title: Self.mangaTitle)
        require(text(app, "Reader fixture manga A page 1"), in: app, "Chapter 1 page 1 of the manga")

        app.buttons["Next Chapter"].tap()
        require(text(app, "Reader fixture manga B"), in: app, "Chapter 2 text with the setting off")
        expectAbsent(app.alerts[Self.alertTitle], in: app, "switch groups alert with the setting off")
        attach(app, name: "Default off opens Chapter 2 without consent")
    }

    func testMangaResumeProposesChapterBAfterChapterAIsFinished() throws {
        let app = try openFixture()
        openSeries(app, title: Self.mangaTitle)
        require(text(app, "Reader fixture manga A page 1"), in: app, "Chapter 1 page 1 of the manga")
        turnOnAskBeforeSwitchingInMangaReader(app)

        // Reading to the last page of Chapter 1 marks it finished.
        let nextPage = app.buttons["Next Page"]
        require(nextPage, in: app, "Next Page control")
        nextPage.tap()
        require(text(app, "Reader fixture manga A page 2"), in: app, "Chapter 1 page 2")
        app.buttons["Close Reader"].tap()

        let resume = app.buttons["Resume"]
        require(resume, in: app, "Resume button on the series screen")
        resume.tap()
        let alert = app.alerts[Self.alertTitle]
        require(alert, in: app, "switch groups alert from Resume")
        requireAlertMessage(alert, in: app, contains: "Group B")
        attach(app, name: "Resume switch groups alert before Chapter 2")

        alert.buttons["Cancel"].tap()
        requireGone(alert, in: app, "switch groups alert after Cancel")
        require(resume, in: app, "Resume button after Cancel")
        expectAbsent(text(app, "Reader fixture manga B"), in: app, "Chapter 2 text after Resume Cancel")

        resume.tap()
        require(alert, in: app, "switch groups alert on second Resume")
        alert.buttons[Self.openUploadLabel].tap()
        require(text(app, "Reader fixture manga B"), in: app, "Chapter 2 text after Resume Open This Upload")
        attach(app, name: "Resume Open This Upload loads Chapter 2 from Group B")
    }

    // MARK: - Fixture and navigation

    /// The fixture's home is empty (its `get_home` is the default), so its series appear only as search results.
    private func openFixture() throws -> XCUIApplication {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "reader-consent", withExtension: "ito", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "reader-consent", withExtension: "ito")
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

    /// Opens a series from the source's search results and starts reading it from its first chapter.
    private func openSeries(_ app: XCUIApplication, title: String) {
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch
        require(entry, in: app, "search result \(title)")
        entry.tap()
        let start = app.buttons["Start"]
        require(start, in: app, "Start button on \(title)")
        start.tap()
    }

    /// Opens the manga reader's Settings sheet and turns on "Ask before switching groups".
    private func turnOnAskBeforeSwitchingInMangaReader(_ app: XCUIApplication) {
        let settings = app.buttons["Reader Settings"]
        require(settings, in: app, "Reader Settings control")
        settings.tap()
        let toggle = app.switches[Self.askToggleLabel]
        require(toggle, in: app, "\(Self.askToggleLabel) toggle in the manga settings")
        for _ in 0..<6 {
            if toggle.isHittable { break }
            app.swipeUp()
        }
        if !toggle.isHittable { failWithHierarchy(app, "\(Self.askToggleLabel) toggle is not hittable") }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        requireValue(toggle, "1", in: app, "\(Self.askToggleLabel) toggle")
        app.navigationBars["Reader Settings"].buttons["Done"].tap()
        require(app.buttons["Next Chapter"], in: app, "Next Chapter control after closing settings")
    }

    /// Opens the novel reader's settings panel on its Reading tab and turns on "Ask before switching groups".
    private func turnOnAskBeforeSwitchingInNovelReader(_ app: XCUIApplication) {
        let settings = app.buttons["Reader Settings"]
        require(settings, in: app, "Reader Settings control")
        settings.tap()
        let reading = app.buttons["Reading"]
        require(reading, in: app, "Reading settings tab")
        reading.tap()
        let toggle = app.switches[Self.askToggleLabel]
        require(toggle, in: app, "\(Self.askToggleLabel) toggle in the novel settings")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        requireValue(toggle, "1", in: app, "\(Self.askToggleLabel) toggle")
        let close = app.descendants(matching: .any)["Close Settings"].firstMatch
        require(close, in: app, "Close Settings overlay")
        // The backdrop spans the screen; its top edge sits under the status bar and the reader header, and the
        // panel covers the lower half, so tap the uncovered band between them.
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        requireGone(close, in: app, "Close Settings overlay after closing")
        require(app.buttons["Next Chapter"], in: app, "Next Chapter control after closing settings")
    }

    // MARK: - Queries and waits

    /// A text element whose label or value holds `value`. Manga pages expose their text as a label;
    /// the novel reader's text view exposes it as a value.
    private func text(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value))
            .firstMatch
    }

    private func requireAlertMessage(
        _ alert: XCUIElement,
        in app: XCUIApplication,
        contains value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let message = alert.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch
        require(message, in: app, "alert message naming \(value)", file: file, line: line)
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

    private func requireValue(
        _ element: XCUIElement,
        _ expected: String,
        in app: XCUIApplication,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        if XCTWaiter().wait(for: [expectation], timeout: 10) != .completed {
            failWithHierarchy(app, "\(what) did not reach value \(expected)", file: file, line: line)
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
