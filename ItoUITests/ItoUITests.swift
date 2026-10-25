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
