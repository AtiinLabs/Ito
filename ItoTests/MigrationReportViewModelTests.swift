import Combine
import Foundation
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class MigrationReportViewModelTests: XCTestCase {
    private let oldPackageRepo = migrationRepository(
        url: "https://b.example",
        packages: [migrationPackage(id: "old.plugin", name: "Old")]
    )

    func testReadOnlyViewModelRejectsEveryRemediationIntent() {
        let viewModel = MigrationReportViewModel(
            readOnlyReport: migrationReport([migrationUnresolved(foreignId: "a", resolvedId: "old")])
        )

        XCTAssertFalse(viewModel.isRemediationAllowed)
        XCTAssertNil(viewModel.install(foreignID: "a"))
        XCTAssertFalse(viewModel.presentRemapPicker(foreignID: "a"))
        XCTAssertFalse(viewModel.skip(foreignID: "a"))
        XCTAssertNil(viewModel.selectRemapTarget(pluginID: "anything"))
        XCTAssertTrue(viewModel.pickerOptions.isEmpty)
        XCTAssertNil(viewModel.disposition(for: "a"))
        XCTAssertEqual(viewModel.activeUnresolvedCount, 1)
    }

    func testCountsTrackSkippedRowsAndEmptyReportIsResolved() {
        let subject = makeMigrationSubject(unresolved: [
            migrationUnresolved(foreignId: "a", resolvedId: "x"),
            migrationUnresolved(foreignId: "b", resolvedId: "y")
        ])
        XCTAssertEqual(subject.viewModel.activeUnresolvedCount, 2)
        XCTAssertFalse(subject.viewModel.isAllResolved)

        XCTAssertTrue(subject.viewModel.skip(foreignID: "a"))
        XCTAssertEqual(subject.viewModel.activeUnresolvedCount, 1)
        XCTAssertTrue(subject.viewModel.skip(foreignID: "b"))
        XCTAssertTrue(subject.viewModel.isAllResolved)

        XCTAssertTrue(makeMigrationSubject(unresolved: []).viewModel.isAllResolved)
    }

    func testInstallRefreshesThenInstallsFirstMatchingPackageInRepositoryOrder() async throws {
        let subject = makeMigrationSubject(unresolved: [
            migrationUnresolved(foreignId: "foreign", resolvedId: "old.plugin")
        ])
        subject.repositories.repositoriesAfterRefresh = [
            migrationRepository(url: "https://a.example", packages: [migrationPackage(id: "other", name: "Other")]),
            oldPackageRepo,
            migrationRepository(url: "https://c.example", packages: [migrationPackage(id: "old.plugin", name: "Old")])
        ]

        let task = try XCTUnwrap(subject.viewModel.install(foreignID: "foreign"))
        await task.value

        XCTAssertEqual(subject.repositories.events, ["refresh", "install:old.plugin@https://b.example"])
        XCTAssertEqual(subject.viewModel.disposition(for: "foreign"), .installed)
        XCTAssertNil(subject.viewModel.activeOperation)
        XCTAssertEqual(subject.logger.events.map(\.kind), [.pluginInstall, .pluginInstall])
        XCTAssertEqual(subject.logger.events.map(\.phase), [.started, .finished])
        XCTAssertEqual(subject.logger.events.last?.outcome, .succeeded)
        XCTAssertEqual(subject.logger.events.first?.operationID, subject.logger.events.last?.operationID)
    }

    func testInstallWithoutMatchingPackagePresentsNotFoundAndKeepsRowPending() async throws {
        let subject = makeMigrationSubject(unresolved: [
            migrationUnresolved(foreignId: "foreign", resolvedId: "old.plugin")
        ])

        let task = try XCTUnwrap(subject.viewModel.install(foreignID: "foreign"))
        await task.value

        XCTAssertEqual(subject.repositories.events, ["refresh"])
        XCTAssertEqual(subject.viewModel.alert, .pluginNotFound(resolvedID: "old.plugin"))
        XCTAssertNil(subject.viewModel.disposition(for: "foreign"))
        XCTAssertEqual(subject.logger.events.last?.outcome, .failed(.pluginUnavailable))
    }

    func testInstallFailureKeepsRowPendingAndPresentsReason() async throws {
        let subject = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "foreign", resolvedId: "old.plugin")],
            repositories: [oldPackageRepo]
        )
        subject.repositories.installError = MigrationTestFailure()

        let task = try XCTUnwrap(subject.viewModel.install(foreignID: "foreign"))
        await task.value

        XCTAssertEqual(
            subject.viewModel.alert,
            .installFailed(foreignID: "foreign", reason: "fixture install failure")
        )
        XCTAssertNil(subject.viewModel.disposition(for: "foreign"))
        XCTAssertNil(subject.viewModel.activeOperation)
        XCTAssertEqual(subject.logger.events.last?.outcome, .failed(.unknown))
    }

    func testSecondOperationIsRejectedSynchronouslyWhileInstallIsClaimed() async throws {
        let subject = makeMigrationSubject(
            unresolved: [
                migrationUnresolved(foreignId: "foreign", resolvedId: "old.plugin"),
                migrationUnresolved(foreignId: "other", resolvedId: "other.plugin")
            ],
            repositories: [oldPackageRepo]
        )

        let task = try XCTUnwrap(subject.viewModel.install(foreignID: "foreign"))

        XCTAssertTrue(subject.viewModel.isBusy)
        XCTAssertNil(subject.viewModel.install(foreignID: "foreign"))
        XCTAssertFalse(subject.viewModel.skip(foreignID: "other"))
        XCTAssertFalse(subject.viewModel.presentRemapPicker(foreignID: "other"))

        await task.value
        XCTAssertEqual(subject.repositories.events.filter { $0 == "refresh" }.count, 1)
    }

    func testInstallEligibilityRequiresNotInstalledAndConfidenceAtLeast45() async throws {
        let subject = makeMigrationSubject(
            unresolved: [
                migrationUnresolved(foreignId: "installed", resolvedId: "old.plugin", isInstalled: true),
                migrationUnresolved(foreignId: "low", resolvedId: "old.plugin", confidence: 44),
                migrationUnresolved(foreignId: "eligible", resolvedId: "old.plugin", confidence: 45)
            ],
            repositories: [oldPackageRepo]
        )

        XCTAssertNil(subject.viewModel.install(foreignID: "installed"))
        XCTAssertNil(subject.viewModel.install(foreignID: "low"))
        let task = try XCTUnwrap(subject.viewModel.install(foreignID: "eligible"))
        await task.value
        XCTAssertEqual(subject.viewModel.disposition(for: "eligible"), .installed)
    }

    func testSkipIsLocalOnlyAndNotRepeatable() {
        let subject = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "foreign", resolvedId: "old.plugin")],
            repositories: [oldPackageRepo]
        )

        XCTAssertTrue(subject.viewModel.skip(foreignID: "foreign"))
        XCTAssertEqual(subject.viewModel.disposition(for: "foreign"), .skipped)
        XCTAssertFalse(subject.viewModel.skip(foreignID: "foreign"))
        XCTAssertNil(subject.viewModel.install(foreignID: "foreign"))
        XCTAssertTrue(subject.repositories.events.isEmpty)
        XCTAssertTrue(subject.remapper.requests.isEmpty)
    }

    func testRemapSendsExactRequestAndClosesPickerSynchronously() async throws {
        let subject = makeMigrationSubject(
            unresolved: [
                migrationUnresolved(foreignId: "a", resolvedId: "old", affectedItemIds: ["i2", "i1"])
            ],
            installed: [pr7bPlugin(id: "new.plugin", name: "New")]
        )

        XCTAssertTrue(subject.viewModel.presentRemapPicker(foreignID: "a"))
        subject.viewModel.pickerSearchText = "typed"
        let task = try XCTUnwrap(subject.viewModel.selectRemapTarget(pluginID: "new.plugin"))

        XCTAssertNil(subject.viewModel.remapPicker)
        XCTAssertEqual(subject.viewModel.pickerSearchText, "")
        await task.value

        XCTAssertEqual(subject.remapper.requests, [
            MigrationRemapRequest(
                foreignID: "a",
                oldPluginID: "old",
                newPluginID: "new.plugin",
                affectedItemIDs: ["i2", "i1"]
            )
        ])
        XCTAssertEqual(subject.viewModel.disposition(for: "a"), .remapped(aliasSaved: true))
        XCTAssertEqual(subject.logger.events.map(\.kind), [.relink, .relink])
        XCTAssertEqual(subject.logger.events.last?.outcome, .succeeded)
    }

    func testPreCommitRemapFailureKeepsRowPending() async throws {
        let subject = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "a", resolvedId: "old")],
            installed: [pr7bPlugin(id: "new.plugin", name: "New")]
        )
        let failure = LibrarySourceRemapper.RemapError.destinationExists("x")
        subject.remapper.response = .failure(failure)

        XCTAssertTrue(subject.viewModel.presentRemapPicker(foreignID: "a"))
        let task = try XCTUnwrap(subject.viewModel.selectRemapTarget(pluginID: "new.plugin"))
        await task.value

        XCTAssertEqual(subject.viewModel.alert, .remapFailed(reason: failure.localizedDescription))
        XCTAssertNil(subject.viewModel.disposition(for: "a"))
        XCTAssertEqual(subject.logger.events.last?.outcome, .failed(.persistence))
    }

    func testAliasFailureAfterCommitMarksRowResolvedWithoutRetry() async throws {
        let subject = makeMigrationSubject(
            unresolved: [
                migrationUnresolved(foreignId: "a", resolvedId: "old"),
                migrationUnresolved(foreignId: "b", resolvedId: "other")
            ],
            installed: [pr7bPlugin(id: "new.plugin", name: "New")]
        )
        subject.remapper.response = .success(.remappedAliasNotSaved)

        XCTAssertTrue(subject.viewModel.presentRemapPicker(foreignID: "a"))
        let task = try XCTUnwrap(subject.viewModel.selectRemapTarget(pluginID: "new.plugin"))
        await task.value

        XCTAssertEqual(subject.viewModel.disposition(for: "a"), .remapped(aliasSaved: false))
        XCTAssertEqual(subject.viewModel.activeUnresolvedCount, 1)
        XCTAssertEqual(subject.viewModel.alert, .remapAliasNotSaved)
        XCTAssertEqual(subject.logger.events.last?.outcome, .partiallySucceeded(.persistence))
        XCTAssertFalse(subject.viewModel.presentRemapPicker(foreignID: "a"))
        XCTAssertNil(subject.viewModel.install(foreignID: "a"))
        XCTAssertEqual(subject.remapper.requests.count, 1)
    }

    func testPickerUnionDeduplicatesSortsAndFilters() {
        let subject = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "a", resolvedId: "old")],
            repositories: [
                migrationRepository(url: "https://r.example", packages: [
                    migrationPackage(id: "b.id", name: "Beta Repo"),
                    migrationPackage(id: "a.id", name: "alpha"),
                    migrationPackage(id: "c.id", name: "Alpha")
                ])
            ],
            installed: [pr7bPlugin(id: "b.id", name: "Beta")]
        )

        XCTAssertEqual(subject.viewModel.pickerOptions.map(\.id), ["a.id", "c.id", "b.id"])
        XCTAssertEqual(subject.viewModel.pickerOptions.last?.name, "Beta")
        XCTAssertEqual(subject.viewModel.pickerOptions.last?.isInstalled, true)

        subject.viewModel.pickerSearchText = "BETA"
        XCTAssertEqual(subject.viewModel.filteredPickerOptions.map(\.id), ["b.id"])
        subject.viewModel.pickerSearchText = "c.ID"
        XCTAssertEqual(subject.viewModel.filteredPickerOptions.map(\.id), ["c.id"])
    }

    func testCancellingPickerPerformsNoRemapAndResetsSearch() {
        let subject = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "a", resolvedId: "old")],
            installed: [pr7bPlugin(id: "new.plugin", name: "New")]
        )

        XCTAssertTrue(subject.viewModel.presentRemapPicker(foreignID: "a"))
        subject.viewModel.pickerSearchText = "x"
        subject.viewModel.cancelRemapPicker()

        XCTAssertNil(subject.viewModel.remapPicker)
        XCTAssertEqual(subject.viewModel.pickerSearchText, "")
        XCTAssertTrue(subject.remapper.requests.isEmpty)
        XCTAssertNil(subject.viewModel.selectRemapTarget(pluginID: "new.plugin"))
    }

    func testUnknownPluginSelectionIsRejectedAndPickerStaysOpen() {
        let subject = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "a", resolvedId: "old")],
            installed: [pr7bPlugin(id: "new.plugin", name: "New")]
        )

        XCTAssertTrue(subject.viewModel.presentRemapPicker(foreignID: "a"))
        XCTAssertNil(subject.viewModel.selectRemapTarget(pluginID: "missing"))
        XCTAssertEqual(subject.viewModel.remapPicker?.foreignID, "a")
        XCTAssertTrue(subject.remapper.requests.isEmpty)
    }

    func testPublishedPluginCatalogUpdatesPickerOptions() {
        let subject = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "a", resolvedId: "old")]
        )

        subject.plugins.publish(["n.id": pr7bPlugin(id: "n.id", name: "New")])

        XCTAssertEqual(subject.viewModel.pickerOptions.map(\.id), ["n.id"])
        XCTAssertEqual(subject.viewModel.pickerOptions.first?.isInstalled, true)
    }

    private func startRemap(_ subject: MigrationSubject) throws -> Task<Void, Never> {
        XCTAssertTrue(subject.viewModel.presentRemapPicker(foreignID: "a"))
        return try XCTUnwrap(subject.viewModel.selectRemapTarget(pluginID: "new.plugin"))
    }

    func testReleasingViewModelDuringRemapStillFinishesDurableWorkAndLogs() async throws {
        var subject: MigrationSubject? = makeMigrationSubject(
            unresolved: [migrationUnresolved(foreignId: "a", resolvedId: "old")],
            installed: [pr7bPlugin(id: "new.plugin", name: "New")]
        )
        let logger = try XCTUnwrap(subject?.logger)
        let remapper = try XCTUnwrap(subject?.remapper)
        weak var weakViewModel = subject?.viewModel
        let task = try startRemap(try XCTUnwrap(subject))
        subject = nil

        await task.value
        XCTAssertNil(weakViewModel)
        XCTAssertEqual(remapper.requests.count, 1)
        XCTAssertEqual(logger.events.last?.outcome, .succeeded)
    }

    func testFormattedLogsNeverContainIdentifiersOrErrorText() async throws {
        let subject = makeMigrationSubject(
            unresolved: [
                migrationUnresolved(
                    foreignId: "secret-foreign",
                    resolvedId: "secret-plugin",
                    affectedItemIds: ["secret-item"]
                )
            ],
            repositories: [
                migrationRepository(url: "https://secret-repo.example", packages: [
                    migrationPackage(id: "secret-plugin", name: "Secret")
                ])
            ]
        )
        subject.repositories.installError = MigrationTestFailure()
        let installTask = try XCTUnwrap(subject.viewModel.install(foreignID: "secret-foreign"))
        await installTask.value

        subject.plugins.publish(["secret-plugin": pr7bPlugin(id: "secret-plugin", name: "Secret")])
        subject.remapper.response = .failure(MigrationTestFailure())
        XCTAssertTrue(subject.viewModel.presentRemapPicker(foreignID: "secret-foreign"))
        let remapTask = try XCTUnwrap(subject.viewModel.selectRemapTarget(pluginID: "secret-plugin"))
        await remapTask.value

        XCTAssertFalse(subject.logger.formattedMessages.isEmpty)
        for message in subject.logger.formattedMessages {
            for secret in ["secret-foreign", "secret-plugin", "secret-item", "secret-repo", "fixture install failure"] {
                XCTAssertFalse(message.contains(secret), "Leaked \(secret) in \(message)")
            }
        }
    }
}
