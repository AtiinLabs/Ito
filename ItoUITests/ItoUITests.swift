//
//  ItoUITests.swift
//  ItoUITests
//
//  Created by caocao on 3/3/26.
//

import XCTest

final class ItoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        // These flows assert portrait layout; a launch run in another UI configuration
        // can leave the device rotated.
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testRepositoryDeepLinkConfirmsAdditionAndIsConsumedOnce() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-storage",
            "--ui-test-repository-deep-link"
        ]
        app.launch()

        let browseTab = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browseTab.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { browseTab.isSelected })

        // The repository list opens on its own and a toast confirms the addition.
        XCTAssertTrue(app.staticTexts["Repository added"].waitForExistence(timeout: 20))
        let repositoryName = app.staticTexts["UI Test Repository"]
        XCTAssertTrue(repositoryName.waitForExistence(timeout: 20))
        let repositoryNames = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "UI Test Repository")
        )
        XCTAssertEqual(repositoryNames.count, 1)

        let redeliver = app.buttons["redeliver-repository-deep-link"]
        XCTAssertTrue(redeliver.waitForExistence(timeout: 10))
        redeliver.tap()

        XCTAssertTrue(app.staticTexts["Already added"].waitForExistence(timeout: 10))
        XCTAssertEqual(repositoryNames.count, 1)
        XCTAssertFalse(app.staticTexts["Failed to add repository. Please try again."].exists)
    }

    @MainActor
    func testRepositoryRemovedAfterConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-storage",
            "--ui-test-repository-deep-link"
        ]
        app.launch()

        // The deep link opens the repository list.
        let repositoryName = app.staticTexts["UI Test Repository"]
        XCTAssertTrue(repositoryName.waitForExistence(timeout: 20))
        repositoryName.swipeLeft()

        let swipeRemove = app.buttons["Remove"]
        XCTAssertTrue(swipeRemove.waitForExistence(timeout: 10))
        swipeRemove.tap()

        let confirmRemove = app.sheets.buttons["Remove"]
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 10))
        confirmRemove.tap()

        XCTAssertTrue(app.staticTexts["No Repositories"].waitForExistence(timeout: 10))
        XCTAssertFalse(repositoryName.exists)
    }

    @MainActor
    func testBackupWipeRequiresTwoConfirmations() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-storage",
            "--ui-test-backup-wipe"
        ]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        settingsTab.tap()
        let backupLink = app.staticTexts["Backup & Restore"]
        XCTAssertTrue(backupLink.waitForExistence(timeout: 20))
        backupLink.tap()

        let fixtureState = app.staticTexts["backup-fixture-state"]
        XCTAssertTrue(fixtureState.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 30) { fixtureState.label == "Fixture item present" })

        let restoreButton = app.buttons["Restore from Backup"]
        XCTAssertTrue(waitUntil(timeout: 30) { restoreButton.isEnabled })
        restoreButton.tap()
        XCTAssertTrue(app.staticTexts["How would you like to restore?"].waitForExistence(timeout: 10))
        app.buttons["Wipe and Replace Library"].tap()
        XCTAssertTrue(app.staticTexts["Wipe and Replace Library?"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()

        XCTAssertTrue(waitUntil(timeout: 10) { fixtureState.label == "Fixture item present" })
        XCTAssertFalse(app.navigationBars["Restore Report"].exists)

        restoreButton.tap()
        XCTAssertTrue(app.staticTexts["How would you like to restore?"].waitForExistence(timeout: 10))
        app.buttons["Wipe and Replace Library"].tap()
        XCTAssertTrue(app.staticTexts["Wipe and Replace Library?"].waitForExistence(timeout: 10))
        app.buttons["Wipe and Replace"].tap()

        let report = app.navigationBars["Restore Report"]
        XCTAssertTrue(report.waitForExistence(timeout: 60))
        app.buttons["Acknowledge"].tap()
        XCTAssertTrue(waitUntil(timeout: 30) { fixtureState.label == "Fixture item removed" })
    }

    @MainActor
    func testLibraryItemRemovedFromContextMenu() throws {
        let app = launchWithLibraryFixture()
        let item = app.staticTexts["Disposable Backup Fixture"]
        item.press(forDuration: 1.2)
        let menuRemove = app.buttons["Remove from Library"]
        XCTAssertTrue(menuRemove.waitForExistence(timeout: 10))
        menuRemove.tap()

        confirmLibraryRemoval(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { !item.exists })
    }

    @MainActor
    func testLibraryItemRemovedInEditMode() throws {
        let app = launchWithLibraryFixture()
        let item = app.staticTexts["Disposable Backup Fixture"]
        app.buttons["Edit"].tap()
        let minus = app.buttons["Remove Disposable Backup Fixture"]
        XCTAssertTrue(minus.waitForExistence(timeout: 10))
        minus.tap()

        confirmLibraryRemoval(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { !item.exists })
    }

    @MainActor
    func testLongPressOutlinesPageWordsAndATappedWordOpensTheDictionary() throws {
        let app = launchWithMangaReaderFixture()
        let page = app.images["Page 1"]
        let header = app.staticTexts["Lookup Fixture"]
        XCTAssertTrue(header.exists)

        page.press(forDuration: 1.2)
        let hello = app.buttons["HELLO"]
        XCTAssertTrue(hello.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["WORLD"].exists)
        // Lifting the finger after the long press is not also a tap: the controls stay. The
        // controls fade out over 0.2 s, so check after that.
        XCTAssertFalse(waitUntil(timeout: 1) { !header.exists })

        hello.tap()
        // The system dictionary opens at the word's plain form.
        let entry = app.navigationBars["hello"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        app.buttons["DDUIDone"].tap()
        // Closing it returns to the reader, still outlined for the next word.
        XCTAssertTrue(waitUntil(timeout: 10) { !entry.exists && hello.isHittable })
        XCTAssertTrue(header.exists)

        app.buttons["WORLD"].tap()
        let secondEntry = app.navigationBars["world"]
        XCTAssertTrue(secondEntry.waitForExistence(timeout: 10))
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitUntil(timeout: 10) { !secondEntry.exists && hello.isHittable })

        // A tap beside the words leaves lookup without toggling the controls.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !hello.exists })
        XCTAssertFalse(waitUntil(timeout: 1) { !header.exists })
    }

    @MainActor
    func testWebtoonPagesStillScrollAndLookUpWords() throws {
        let app = launchWithMangaReaderFixture()
        app.buttons["Reading Mode"].tap()
        app.buttons["Webtoon"].tap()

        // Dragging a page scrolls the strip; the long press does not hold on to the drag.
        let secondPage = app.images["Page 2"]
        XCTAssertTrue(app.images["Page 1"].waitForExistence(timeout: 10))
        app.images["Page 1"].swipeUp(velocity: .fast)
        XCTAssertTrue(waitUntil(timeout: 10) { secondPage.exists && secondPage.isHittable })

        secondPage.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["GOODBYE"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["MOON"].exists)
    }

    @MainActor
    func testReaderPageTapAndSwipeStillWorkWithWordLookupOn() throws {
        let app = launchWithMangaReaderFixture()
        let header = app.staticTexts["Lookup Fixture"]

        app.images["Page 1"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !header.exists })

        app.images["Page 1"].swipeLeft()
        XCTAssertTrue(app.images["Page 2"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { app.images["Page 2"].isHittable })
    }

    @MainActor
    func testLookupCanBeTurnedOffAndBackOnInReaderSettings() throws {
        let app = launchWithMangaReaderFixture()
        app.buttons["Reader Settings"].tap()
        let toggle = app.switches["Look Up Words"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { toggle.value as? String == "0" })
        app.buttons["Done"].tap()

        app.images["Page 1"].press(forDuration: 1.2)
        XCTAssertFalse(waitUntil(timeout: 2) { app.buttons["HELLO"].exists })
        // A long press with lookup off may hide the controls, like any other page tap.
        if !app.buttons["Reader Settings"].isHittable { app.images["Page 1"].tap() }
        app.buttons["Reader Settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { toggle.value as? String == "1" })
        app.buttons["Done"].tap()
        app.images["Page 1"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["HELLO"].waitForExistence(timeout: 30))
    }

    @MainActor
    func testDoubleTapZoomKeepsLookupAlignedWithThePage() throws {
        let app = launchWithMangaReaderFixture()
        let page = app.images["Page 1"]
        page.press(forDuration: 1.2)
        let world = app.buttons["WORLD"]
        XCTAssertTrue(world.waitForExistence(timeout: 30))
        let unzoomedWidth = world.frame.width
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !world.exists })

        page.doubleTap()
        page.press(forDuration: 1.2)
        XCTAssertTrue(world.waitForExistence(timeout: 30))
        // The word's hit area must grow with the page, rather than stay on an unscaled overlay.
        XCTAssertGreaterThan(world.frame.width, unzoomedWidth * 1.5)
        world.tap()
        XCTAssertTrue(app.navigationBars["world"].waitForExistence(timeout: 10))
    }

    /// Launches with the two-page reader fixture open on its first page.
    @MainActor
    private func launchWithMangaReaderFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-storage", "--ui-test-manga-reader"]
        app.launch()
        let open = app.buttons["open-manga-reader-fixture"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        XCTAssertTrue(app.images["Page 1"].waitForExistence(timeout: 20))
        return app
    }

    /// Launches with one disposable library item and shows it on the Library tab.
    @MainActor
    private func launchWithLibraryFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-storage", "--ui-test-backup-wipe"]
        app.launch()
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        libraryTab.tap()
        XCTAssertTrue(app.staticTexts["Disposable Backup Fixture"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func confirmLibraryRemoval(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Remove from Library?"].waitForExistence(timeout: 10))
        let confirm = app.buttons.matching(identifier: "Remove").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }
}
