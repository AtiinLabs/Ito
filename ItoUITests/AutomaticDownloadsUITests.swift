import Foundation
import XCTest

/// Automatic downloads from a person's side: enroll a series from its screen, read its status, open the management
/// screen from Downloads, and open the review of a chapter that waits for a decision.
///
/// The enrolled series is the reader-consent fixture's manga, checked for real through the fixture source. The series
/// with a waiting chapter is seeded by the app (`--ui-test-automatic-downloads`) through the store's own entry points,
/// because a fixed fixture source cannot change its answer between two checks.
@MainActor
final class AutomaticDownloadsUITests: XCTestCase {
    private static let fixtureSourceName = "Reader Consent Fixture"
    private static let sourceSearchPrompt = "Search source..."
    private static let sourceSearchText = "Reader Consent"
    private static let mangaTitle = "Reader Consent Manga"
    private static let seededTitle = "Seeded Review Series"
    private static let seededChapter = "Seeded Unplaced Chapter"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnrollSeeTheStatusOpenTheManagementScreenAndReviewAWaitingChapter() throws {
        let app = try openFixture()
        openSeries(app, title: Self.mangaTitle)

        // The series is not in the Library yet: the row says what is needed and offers no action.
        let unavailable = element(app, "automaticDownloadsUnavailableRow")
        scrollTo(unavailable, in: app, "the automatic downloads row of an unsaved series")
        XCTAssertTrue(
            unavailable.label.contains("Add to Library to download new chapters automatically"),
            "The unsaved series' row names what is needed: \(unavailable.label)"
        )
        attach(app, name: "1 Series not in the Library: automatic downloads need it saved")

        let save = app.buttons["Save"]
        require(save, in: app, "Save button")
        save.tap()

        let row = element(app, "automaticDownloadsRow")
        scrollTo(row, in: app, "the automatic downloads row of a saved series")
        XCTAssertTrue(row.label.contains("Download New Chapters Automatically"), row.label)
        attach(app, name: "2 Saved series: the rule is off")

        row.tap()
        let turnOn = app.buttons["ruleSaveButton"]
        require(app.buttons["closeRuleSheet"], in: app, "rule sheet")
        attach(app, name: "3 Rule sheet before turning the rule on")
        // The form is long: its actions are below the settings.
        scrollTo(turnOn, in: app, "Turn On button")
        XCTAssertEqual(turnOn.label, "Turn On")
        attach(app, name: "3b Rule sheet actions")
        turnOn.tap()

        // The sheet closes, and the series screen says what the rule is doing: it was checked through the fixture source.
        requireGone(app.buttons["ruleSaveButton"], in: app, "rule sheet after Turn On")
        let active = element(app, "automaticDownloadsRow")
        let activePredicate = NSPredicate(format: "label CONTAINS %@", "Active")
        let activeExpectation = XCTNSPredicateExpectation(predicate: activePredicate, object: active)
        if XCTWaiter().wait(for: [activeExpectation], timeout: 30) != .completed {
            failWithHierarchy(app, "The rule did not become active after its first check: \(active.label)")
        }
        XCTAssertFalse(active.label.contains("Waiting for a complete chapter list"), active.label)
        attach(app, name: "4 Series screen: the rule is active and was checked")

        // Downloads → Automatic Downloads.
        leaveSeries(app)
        let library = app.tabBars.buttons["Library"]
        require(library, in: app, "Library tab")
        library.tap()
        let downloads = app.buttons["Downloads"]
        require(downloads, in: app, "Downloads button")
        downloads.tap()
        let link = app.buttons["automaticDownloadsLink"]
        require(link, in: app, "Automatic Downloads link on the Downloads screen")
        attach(app, name: "5 Downloads screen with the Automatic Downloads entry")
        link.tap()

        let rows = app.buttons.matching(identifier: "automaticRuleRow")
        require(rows.firstMatch, in: app, "a rule row on the management screen")
        let seeded = rows.containing(NSPredicate(format: "label CONTAINS %@", Self.seededTitle)).firstMatch
        require(seeded, in: app, "the seeded series' rule row")
        XCTAssertTrue(seeded.label.contains("waiting for your decision"), "The row says a decision waits: \(seeded.label)")
        let enrolled = rows.containing(NSPredicate(format: "label CONTAINS %@", Self.mangaTitle)).firstMatch
        require(enrolled, in: app, "the enrolled series' rule row")
        XCTAssertTrue(enrolled.label.contains("Active"), enrolled.label)
        XCTAssertFalse(enrolled.label.contains("waiting for your decision"), enrolled.label)
        XCTAssertTrue(app.switches["attentionNotificationsToggle"].exists, "The notification setting is on the screen")
        XCTAssertEqual(app.switches["attentionNotificationsToggle"].value as? String, "0", "Notifications are off by default")
        attach(app, name: "6 Management screen: both rules, one waiting for a decision")

        // The review of the waiting chapter.
        let review = app.buttons["automaticRuleReviewButton"]
        require(review, in: app, "Review button of the rule that waits")
        review.tap()
        let chapter = app.staticTexts[Self.seededChapter]
        require(chapter, in: app, "the waiting chapter in the review")
        require(app.buttons["dismissEventButton"], in: app, "Dismiss button in the review")
        require(app.buttons["approveEventButton"], in: app, "Download Selected button in the review")
        XCTAssertFalse(app.buttons["approveEventButton"].isEnabled, "Nothing is ticked, so nothing can be downloaded")
        attach(app, name: "7 Review sheet: the chapter that waits for a decision")

        chapter.tap()
        XCTAssertTrue(app.buttons["approveEventButton"].isEnabled, "A ticked chapter can be downloaded")
        attach(app, name: "8 Review sheet with the chapter ticked")
        app.buttons["closeReviewSheet"].tap()
        requireGone(app.buttons["closeReviewSheet"], in: app, "review sheet after Done")
    }

    // MARK: - Fixture and navigation

    private func openFixture() throws -> XCUIApplication {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "reader-consent", withExtension: "ito", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "reader-consent", withExtension: "ito")
        )
        let app = XCUIApplication.english(arguments: ["--ui-test-reset-storage", "--ui-test-automatic-downloads"])
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

    private func openSeries(_ app: XCUIApplication, title: String) {
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch
        require(entry, in: app, "search result \(title)")
        entry.tap()
        require(app.buttons["Save"], in: app, "series screen of \(title)")
    }

    /// Goes back to the tab bar from the series screen.
    private func leaveSeries(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        for _ in 0..<4 where !app.tabBars.buttons["Library"].isHittable {
            if back.exists { back.tap() }
        }
    }

    // MARK: - Queries and waits

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, _ what: String) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        require(element, in: app, what, timeout: 5)
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
