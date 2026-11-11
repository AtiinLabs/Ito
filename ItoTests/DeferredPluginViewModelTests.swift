import Combine
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class DeferredPluginViewModelTests: XCTestCase {
    func testAlreadyInstalledRoutesMangaAnimeAndNovelWithExactRunnerAndPluginIdentity() async throws {
        let cases: [(MediaKind, DeferredPluginMedia)] = [
            (.manga, .manga(Manga(key: "manga", title: "Manga"))),
            (.anime, .anime(Anime(key: "anime", title: "Anime"))),
            (.novel, .novel(Novel(key: "novel", title: "Novel")))
        ]

        for (type, media) in cases {
            let runner = ItoRunner()
            let subject = try makeSubject(
                item: encodedItem(media, pluginType: type),
                installedPluginIDs: ["plugin.exact"],
                runnerResponses: [.immediate(.success(runner))]
            )

            let ready = expectation(description: "\(type) opened")
            let subscription = subject.viewModel.$phase.sink { phase in
                if case .ready = phase { ready.fulfill() }
            }
            subject.viewModel.appear()
            await fulfillment(of: [ready], timeout: 2)
            subscription.cancel()

            XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact"])
            XCTAssertEqual(subject.installer.lookupRequests, [])
            XCTAssertEqual(subject.installer.installRequests, [])
            guard let destination = subject.viewModel.route?.destination else {
                return XCTFail("Expected a typed destination")
            }
            XCTAssertEqual(destination.pluginID, "plugin.exact")
            XCTAssertTrue(destination.runner === runner)
            assert(destination: destination, matches: media)
        }
    }

    func testOnlyTheFirstRouteCarriesTheOpenIntent() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.immediate(.success(ItoRunner())), .immediate(.success(ItoRunner()))],
            openIntent: .resume(preferredScanlator: nil)
        )

        var readyRoutes: [DeferredPluginRoute] = []
        let firstReady = expectation(description: "first route")
        let secondReady = expectation(description: "rebuilt route")
        let subscription = subject.viewModel.$phase.sink { phase in
            guard case .ready(let route) = phase else { return }
            readyRoutes.append(route)
            (readyRoutes.count == 1 ? firstReady : secondReady).fulfill()
        }
        defer { subscription.cancel() }

        subject.viewModel.appear()
        await fulfillment(of: [firstReady], timeout: 2)
        // Leaving and coming back builds a new route for the same series.
        subject.viewModel.disappear()
        subject.viewModel.appear()
        await fulfillment(of: [secondReady], timeout: 2)

        XCTAssertEqual(readyRoutes.map(\.openIntent), [.resume(preferredScanlator: nil), nil])
        XCTAssertNotEqual(readyRoutes[0].id, readyRoutes[1].id)
    }

    func testNovelLibraryItemOpensFromAMultiKindSourceAndInvalidatesIfNovelSupportIsRemoved() async throws {
        let runner = ItoRunner()
        let novel = Novel(key: "novel", title: "Novel")
        let subject = try makeSubject(
            item: encodedItem(.novel(novel), pluginType: .novel),
            installedPluginIDs: ["plugin.exact"],
            installedPluginKinds: [.manga, .novel],
            runnerResponses: [.immediate(.success(runner))]
        )
        let ready = expectation(description: "Novel opened")
        let subscription = subject.viewModel.$phase.sink { phase in
            if case .ready = phase { ready.fulfill() }
        }
        defer { subscription.cancel() }
        subject.viewModel.appear()
        await fulfillment(of: [ready], timeout: 2)

        guard case .novel(let pluginID, let actualRunner, let media) = subject.viewModel.route?.destination else {
            return XCTFail("Expected the saved novel, not a synthetic manga")
        }
        XCTAssertEqual(pluginID, "plugin.exact")
        XCTAssertTrue(actualRunner === runner)
        XCTAssertEqual(media.key, novel.key)

        subject.plugins.publish(["plugin.exact"], supportedKinds: [.manga])
        XCTAssertEqual(subject.viewModel.failure, .pluginTypeMismatch)
        XCTAssertNil(subject.viewModel.route)
        XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact"])
    }

    func testMissingNovelCanSelectAMultiKindPackageWhosePrimaryKindIsManga() async throws {
        let package = candidate(pluginType: .manga, kinds: ["manga", "novel"])
        let subject = try makeSubject(
            item: encodedItem(.novel(Novel(key: "novel", title: "Novel")), pluginType: .novel),
            lookupResponses: [.immediate(package)],
            installResponses: [.suspended]
        )
        let missing = expectation(description: "Missing source detected")
        let installing = expectation(description: "Multi-kind source selected")
        let subscription = subject.viewModel.$phase.sink { phase in
            if case .pluginMissing = phase { missing.fulfill() }
        }
        subject.installer.onInstallSuspended = { installing.fulfill() }
        defer { subscription.cancel() }
        subject.viewModel.appear()
        await fulfillment(of: [missing], timeout: 2)
        subject.viewModel.installMissingPlugin()
        await fulfillment(of: [installing], timeout: 2)

        XCTAssertNil(subject.viewModel.failure)
        XCTAssertEqual(subject.installer.installRequests.first?.package.id, "plugin.exact")
        subject.installer.resolveInstall(at: 0, result: .success(()))
        subject.viewModel.disappear()
    }

    func testMalformedPayloadAndInconsistentMetadataFailBeforeRunnerLoad() async {
        let malformed = makeSubject(
            item: libraryItem(
                rawPayload: Data("not-json".utf8),
                pluginType: .manga,
                isAnime: false
            ),
            installedPluginIDs: ["plugin.exact"]
        )
        malformed.viewModel.appear()
        await waitUntil { malformed.viewModel.failure == .payloadDecode }
        XCTAssertNil(malformed.viewModel.route)
        XCTAssertTrue(malformed.plugins.runnerRequests.isEmpty)

        let inconsistent = makeSubject(
            item: libraryItem(
                rawPayload: (try? JSONEncoder().encode(Anime(key: "anime", title: "Anime"))) ?? Data(),
                pluginType: .anime,
                isAnime: false
            ),
            installedPluginIDs: ["plugin.exact"]
        )
        inconsistent.viewModel.appear()
        await waitUntil { inconsistent.viewModel.failure == .payloadDecode }
        XCTAssertNil(inconsistent.viewModel.route)
        XCTAssertTrue(inconsistent.plugins.runnerRequests.isEmpty)
    }

    func testRunnerFailureIsRecoverableAndRetryPublishesOneStableRoute() async throws {
        let firstRunner = ItoRunner()
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [
                .immediate(.failure(DeferredTestFailure.expected)),
                .immediate(.success(firstRunner))
            ]
        )

        subject.viewModel.appear()
        await waitUntil { subject.viewModel.failure == .runnerLoad }
        XCTAssertNil(subject.viewModel.route)
        subject.viewModel.retry()
        await waitUntil { subject.viewModel.route != nil }
        let routeID = subject.viewModel.route?.id
        subject.viewModel.appear()
        await Task.yield()
        XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact", "plugin.exact"])
        XCTAssertEqual(subject.viewModel.route?.id, routeID)
        XCTAssertTrue(subject.viewModel.route?.destination.runner === firstRunner)
        subject.viewModel.disappear()
        XCTAssertTrue(subject.viewModel.isCancelled)
        XCTAssertNil(subject.viewModel.route)
    }

    func testMissingPackageAndIncompatiblePackageAreExplicitAndUseExactLookup() async throws {
        let missing = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            lookupResponses: [.immediate(nil)]
        )
        missing.viewModel.appear()
        await waitUntil { missing.viewModel.isPluginMissing }
        XCTAssertNil(missing.viewModel.route)
        missing.viewModel.installMissingPlugin()
        await waitUntil { missing.viewModel.isPackageUnavailable }
        XCTAssertEqual(missing.installer.lookupRequests, ["plugin.exact"])
        XCTAssertTrue(missing.installer.installRequests.isEmpty)

        let incompatible = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            lookupResponses: [.immediate(candidate(isCompatible: false, minimumVersion: "99.0"))]
        )
        incompatible.viewModel.appear()
        await waitUntil { incompatible.viewModel.isPluginMissing }
        incompatible.viewModel.installMissingPlugin()
        await waitUntil { incompatible.viewModel.incompatibility == .requiresNewerApp(minimumAppVersion: "99.0") }
        XCTAssertEqual(incompatible.installer.lookupRequests, ["plugin.exact"])
        XCTAssertTrue(incompatible.installer.installRequests.isEmpty)
    }

    func testEachFeedIncompatibilityKeepsSavedDetailsOpenAndInstallsNothing() async throws {
        let directions: [PluginIncompatibility] = [
            .requiresNewerApp(minimumAppVersion: "99.0"),
            .requiresNewerApp(minimumAppVersion: nil),
            .requiresSourceUpdate
        ]
        for direction in directions {
            let subject = try makeSubject(
                item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
                lookupResponses: [.immediate(candidate(incompatibility: direction))],
                offlineReading: InventoryOfflineChapterReading(rows: [])
            )
            subject.viewModel.appear()
            await waitUntil { subject.viewModel.isPluginMissing }
            subject.viewModel.installMissingPlugin()
            await waitUntil { subject.viewModel.incompatibility == direction }
            XCTAssertTrue(subject.viewModel.canOpenSavedDetails, "\(direction) keeps Open Saved Details")
            XCTAssertTrue(subject.installer.installRequests.isEmpty)
        }
    }

    func testAnInstalledSourceRefusedWhenItLoadsKeepsSavedDetailsOpenInEachDirection() async throws {
        let refusals: [PluginIncompatibility] = [
            .requiresNewerApp(minimumAppVersion: nil),
            .requiresSourceUpdate,
            .unsupportedFile
        ]
        for refusal in refusals {
            let subject = try makeSubject(
                item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
                installedPluginIDs: ["plugin.exact"],
                runnerResponses: [.immediate(.failure(refusal))],
                offlineReading: InventoryOfflineChapterReading(rows: [])
            )
            subject.viewModel.appear()
            await waitUntil { subject.viewModel.failure == .runnerLoad }
            XCTAssertEqual(subject.viewModel.runnerRefusal, refusal)
            XCTAssertTrue(subject.viewModel.canOpenSavedDetails, "\(refusal) keeps Open Saved Details")
        }
    }

    func testRetryClearsTheStoredRefusalWhileTheSourceLoadsAgain() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.immediate(.failure(PluginIncompatibility.requiresSourceUpdate)), .suspended],
            offlineReading: InventoryOfflineChapterReading(rows: [])
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.failure == .runnerLoad }
        XCTAssertEqual(subject.viewModel.runnerRefusal, .requiresSourceUpdate)

        subject.viewModel.retry()
        await waitUntil { subject.plugins.pendingRunnerCount == 1 }
        XCTAssertNil(subject.viewModel.runnerRefusal, "a retry never shows the previous attempt's direction")
        XCTAssertTrue(subject.viewModel.isBusy)
    }

    func testAnInstallRefusedWhenInstallingIsKeptWithItsDirection() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            lookupResponses: [.immediate(candidate())],
            installResponses: [.immediate(.failure(PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil)))]
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.viewModel.failure == .install }
        XCTAssertEqual(subject.viewModel.installRefusal, .requiresNewerApp(minimumAppVersion: nil))
    }

    func testAnInstalledSourceTooOldForThisItoOffersItsCompatibleBuildAndRecoversAfterInstall() async throws {
        let runner = ItoRunner()
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.immediate(.failure(PluginIncompatibility.requiresSourceUpdate)), .immediate(.success(runner))],
            lookupResponses: [.immediate(candidate())],
            installResponses: [.suspended]
        )

        subject.viewModel.appear()
        await waitUntil { subject.viewModel.failure == .runnerLoad }
        XCTAssertEqual(subject.viewModel.runnerRefusal, .requiresSourceUpdate)

        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.installRequests.count == 1 }
        XCTAssertEqual(subject.installer.lookupRequests, ["plugin.exact"])
        XCTAssertNil(subject.viewModel.runnerRefusal, "starting the update clears the previous refusal")

        subject.plugins.publish(["plugin.exact"])
        XCTAssertTrue(subject.viewModel.isInstalling)
        XCTAssertNil(subject.viewModel.route)

        subject.installer.resolveInstall(at: 0, result: .success(()))
        await waitUntil { subject.viewModel.route != nil }
        XCTAssertTrue(subject.viewModel.route?.destination.runner === runner)
    }

    func testAnInstalledSourceWithNoCompatibleBuildShowsTheRefusalAndRefreshSourcesLooksAgain() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.immediate(.failure(PluginIncompatibility.requiresSourceUpdate))],
            lookupResponses: [
                .immediate(candidate(incompatibility: .requiresSourceUpdate)),
                .immediate(candidate())
            ],
            installResponses: [.suspended],
            offlineReading: InventoryOfflineChapterReading(rows: [])
        )

        subject.viewModel.appear()
        await waitUntil { subject.viewModel.failure == .runnerLoad }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.viewModel.incompatibility == .requiresSourceUpdate }
        XCTAssertTrue(subject.installer.installRequests.isEmpty)
        XCTAssertTrue(subject.viewModel.canOpenSavedDetails)

        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.installRequests.count == 1 }
        XCTAssertEqual(subject.installer.lookupRequests, ["plugin.exact", "plugin.exact"])
    }

    func testAnInstalledSourceThatNeedsANewerItoIsNotLookedUpForAnUpdate() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.immediate(.failure(PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil)))],
            lookupResponses: [.immediate(candidate())]
        )

        subject.viewModel.appear()
        await waitUntil { subject.viewModel.failure == .runnerLoad }
        subject.viewModel.installMissingPlugin()

        XCTAssertEqual(subject.viewModel.failure, .runnerLoad)
        XCTAssertTrue(subject.installer.lookupRequests.isEmpty)
        XCTAssertTrue(subject.installer.installRequests.isEmpty)
    }

    func testInstallSuppressesDuplicatesAndRequiresCompletionPlusAuthoritativePublication() async throws {
        let runner = ItoRunner()
        let package = candidate()
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            runnerResponses: [.immediate(.success(runner))],
            lookupResponses: [.immediate(package)],
            installResponses: [.suspended]
        )

        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.installRequests.count == 1 }
        XCTAssertEqual(subject.installer.lookupRequests, ["plugin.exact"])
        XCTAssertEqual(subject.installer.installRequests.first?.package.id, "plugin.exact")
        XCTAssertNil(subject.viewModel.route)

        subject.plugins.publish(["plugin.exact"])
        await Task.yield()
        XCTAssertTrue(subject.plugins.runnerRequests.isEmpty)
        XCTAssertTrue(subject.viewModel.isInstalling)

        subject.installer.resolveInstall(at: 0, result: .success(()))
        await waitUntil { subject.viewModel.route != nil }
        XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact"])
        XCTAssertTrue(subject.viewModel.route?.destination.runner === runner)
    }

    func testInstallCompletionWaitsForAuthorityAndFailureCanRetryWithoutFalseNavigation() async throws {
        let runner = ItoRunner()
        let package = candidate(pluginType: .novel)
        let subject = try makeSubject(
            item: encodedItem(.novel(Novel(key: "novel", title: "Novel")), pluginType: .novel),
            runnerResponses: [.immediate(.success(runner))],
            lookupResponses: [.immediate(package), .immediate(package)],
            installResponses: [.suspended, .suspended]
        )

        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.installRequests.count == 1 }
        subject.installer.resolveInstall(at: 0, result: .failure(DeferredTestFailure.expected))
        await waitUntil { subject.viewModel.failure == .install }
        XCTAssertNil(subject.viewModel.route)

        subject.viewModel.retry()
        await waitUntil { subject.installer.installRequests.count == 2 }
        subject.installer.resolveInstall(at: 0, result: .success(()))
        await Task.yield()
        XCTAssertTrue(subject.viewModel.isInstalling)
        XCTAssertNil(subject.viewModel.route)
        XCTAssertTrue(subject.plugins.runnerRequests.isEmpty)

        subject.plugins.publish(["plugin.exact"])
        await waitUntil { subject.viewModel.route != nil }
        XCTAssertEqual(subject.installer.installRequests.count, 2)
        XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact"])
    }

    func testAuthoritativeExternalPluginPublicationLoadsWithoutInstallation() async throws {
        let subject = try makeSubject(
            item: encodedItem(.anime(Anime(key: "anime", title: "Anime")), pluginType: .anime),
            runnerResponses: [
                .immediate(.success(ItoRunner())),
                .immediate(.success(ItoRunner()))
            ]
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.plugins.publish(["unrelated"])
        await Task.yield()
        XCTAssertNil(subject.viewModel.route)
        subject.plugins.publish(["unrelated", "plugin.exact"])
        await waitUntil { subject.viewModel.route != nil }
        XCTAssertTrue(subject.installer.lookupRequests.isEmpty)
        XCTAssertTrue(subject.installer.installRequests.isEmpty)
        XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact"])

        subject.plugins.publish([])
        await waitUntil { subject.viewModel.isPluginMissing }
        XCTAssertNil(subject.viewModel.route)
        subject.plugins.publish(["plugin.exact"])
        await waitUntil { subject.viewModel.route != nil }
        XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact", "plugin.exact"])
    }

    func testDisappearDuringLookupIgnoresLateNonCooperativePackageResult() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            lookupResponses: [.suspended]
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.pendingLookupCount == 1 }
        subject.viewModel.disappear()
        XCTAssertTrue(subject.viewModel.isCancelled)
        subject.installer.resolveLookup(at: 0, candidate: candidate())
        await Task.yield()
        XCTAssertTrue(subject.viewModel.isCancelled)
        XCTAssertTrue(subject.installer.installRequests.isEmpty)
        XCTAssertNil(subject.viewModel.route)
    }

    func testDisappearDuringInstallAllowsDurableAuthorityButNeverNavigates() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            lookupResponses: [.immediate(candidate())],
            installResponses: [.suspended]
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.pendingInstallCount == 1 }
        subject.viewModel.disappear()
        subject.plugins.publish(["plugin.exact"])
        subject.installer.resolveInstall(at: 0, result: .success(()))
        await Task.yield()
        XCTAssertEqual(Set(subject.plugins.libraryPluginSnapshot.plugins.keys), ["plugin.exact"])
        XCTAssertNil(subject.viewModel.route)
        XCTAssertTrue(subject.viewModel.isCancelled)
        XCTAssertTrue(subject.plugins.runnerRequests.isEmpty)
    }

    func testLatePackageResultCannotStartInstallAfterNewerOperationSucceeds() async throws {
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            runnerResponses: [.immediate(.success(ItoRunner()))],
            lookupResponses: [.suspended, .immediate(candidate())],
            installResponses: [.suspended]
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.pendingLookupCount == 1 }
        subject.viewModel.disappear()
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.pendingInstallCount == 1 }
        subject.plugins.publish(["plugin.exact"])
        subject.installer.resolveInstall(at: 0, result: .success(()))
        await waitUntil { subject.viewModel.route != nil }
        let routeID = subject.viewModel.route?.id

        subject.installer.resolveLookup(at: 0, candidate: candidate())
        await Task.yield()
        XCTAssertEqual(subject.viewModel.route?.id, routeID)
        XCTAssertEqual(subject.installer.installRequests.count, 1)
        XCTAssertEqual(subject.plugins.runnerRequests, ["plugin.exact"])
    }

    func testLateInstallFailureCannotOverwriteNewerRetrySuccess() async throws {
        let currentRunner = ItoRunner()
        let subject = try makeSubject(
            item: encodedItem(.novel(Novel(key: "novel", title: "Novel")), pluginType: .novel),
            runnerResponses: [.immediate(.success(currentRunner))],
            lookupResponses: [
                .immediate(candidate(pluginType: .novel)),
                .immediate(candidate(pluginType: .novel))
            ],
            installResponses: [.suspended, .suspended]
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.pendingInstallCount == 1 }
        subject.viewModel.disappear()
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.installer.pendingInstallCount == 2 }
        subject.plugins.publish(["plugin.exact"])
        subject.installer.resolveInstall(at: 1, result: .success(()))
        await waitUntil { subject.viewModel.route != nil }
        let routeID = subject.viewModel.route?.id

        subject.installer.resolveInstall(at: 0, result: .failure(DeferredTestFailure.expected))
        await Task.yield()
        XCTAssertEqual(subject.viewModel.route?.id, routeID)
        XCTAssertNil(subject.viewModel.failure)
        XCTAssertTrue(subject.viewModel.route?.destination.runner === currentRunner)
    }

    func testLateRunnerAndDecodeCompletionsCannotOverwriteNewerSuccess() async {
        let oldRunner = ItoRunner()
        let currentRunner = ItoRunner()
        let media = DeferredPluginMedia.manga(Manga(key: "manga", title: "Manga"))
        let decoder = DeferredDecoderFake(responses: [.suspended, .immediate(.success(media))])
        let subject = makeSubject(
            item: libraryItem(rawPayload: Data(), pluginType: .manga, isAnime: false),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.immediate(.success(currentRunner))],
            decoder: decoder
        )

        subject.viewModel.appear()
        await waitUntil { decoder.pendingCount == 1 }
        subject.viewModel.disappear()
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.route != nil }
        let currentRouteID = subject.viewModel.route?.id
        decoder.resolve(at: 0, result: .failure(DeferredTestFailure.expected))
        await Task.yield()
        XCTAssertEqual(subject.viewModel.route?.id, currentRouteID)
        XCTAssertTrue(subject.viewModel.route?.destination.runner === currentRunner)

        let runnerSubject = makeSubject(
            item: libraryItem(rawPayload: Data(), pluginType: .manga, isAnime: false),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.suspended, .immediate(.success(currentRunner))],
            decoder: DeferredDecoderFake(
                responses: [.immediate(.success(media)), .immediate(.success(media))]
            )
        )
        runnerSubject.viewModel.appear()
        await waitUntil { runnerSubject.plugins.pendingRunnerCount == 1 }
        runnerSubject.viewModel.disappear()
        runnerSubject.viewModel.appear()
        await waitUntil { runnerSubject.viewModel.route != nil }
        let newRouteID = runnerSubject.viewModel.route?.id
        runnerSubject.plugins.resolveRunner(at: 0, result: .success(oldRunner))
        await Task.yield()
        XCTAssertEqual(runnerSubject.viewModel.route?.id, newRouteID)
        XCTAssertTrue(runnerSubject.viewModel.route?.destination.runner === currentRunner)
    }

    func testPackageLookupFailureIsDistinctRetryableAndLateFailureIsIgnored() async throws {
        let runner = ItoRunner()
        let subject = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            runnerResponses: [.immediate(.success(runner))],
            lookupResponses: [
                .failure(DeferredTestFailure.expected),
                .immediate(candidate())
            ],
            installResponses: [.suspended]
        )

        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }
        subject.viewModel.installMissingPlugin()
        await waitUntil { subject.viewModel.failure == .packageLookup }
        XCTAssertTrue(subject.installer.installRequests.isEmpty)
        XCTAssertNil(subject.viewModel.route)

        subject.viewModel.retry()
        await waitUntil { subject.installer.pendingInstallCount == 1 }
        subject.plugins.publish(["plugin.exact"])
        subject.installer.resolveInstall(at: 0, result: .success(()))
        await waitUntil { subject.viewModel.route != nil }
        XCTAssertEqual(subject.installer.lookupRequests, ["plugin.exact", "plugin.exact"])
        XCTAssertTrue(subject.viewModel.route?.destination.runner === runner)

        let cancelled = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            lookupResponses: [.suspended]
        )
        cancelled.viewModel.appear()
        await waitUntil { cancelled.viewModel.isPluginMissing }
        cancelled.viewModel.installMissingPlugin()
        await waitUntil { cancelled.installer.pendingLookupCount == 1 }
        cancelled.viewModel.disappear()
        cancelled.installer.resolveLookup(
            at: 0,
            result: .failure(DeferredTestFailure.expected)
        )
        await Task.yield()
        XCTAssertTrue(cancelled.viewModel.isCancelled)
        XCTAssertNil(cancelled.viewModel.route)
        XCTAssertTrue(cancelled.installer.installRequests.isEmpty)
    }

    func testInstalledAndRepositoryPluginTypeMismatchesNeverLoadInstallOrNavigate() async throws {
        let installedMismatch = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            installedPluginKinds: [.novel]
        )
        installedMismatch.viewModel.appear()
        await waitUntil { installedMismatch.viewModel.failure == .pluginTypeMismatch }
        XCTAssertTrue(installedMismatch.plugins.runnerRequests.isEmpty)
        XCTAssertTrue(installedMismatch.installer.lookupRequests.isEmpty)
        XCTAssertNil(installedMismatch.viewModel.route)

        let packageMismatch = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            lookupResponses: [.immediate(candidate(pluginType: .novel))]
        )
        packageMismatch.viewModel.appear()
        await waitUntil { packageMismatch.viewModel.isPluginMissing }
        packageMismatch.viewModel.installMissingPlugin()
        await waitUntil { packageMismatch.viewModel.failure == .pluginTypeMismatch }
        XCTAssertTrue(packageMismatch.installer.installRequests.isEmpty)
        XCTAssertTrue(packageMismatch.plugins.runnerRequests.isEmpty)
        XCTAssertNil(packageMismatch.viewModel.route)
    }

    func testMangaAndNovelPayloadMetadataMismatchesFailBeforeRunnerLoad() async throws {
        let encodedManga = try JSONEncoder().encode(Manga(key: "manga", title: "Manga"))
        let mangaAsNovel = makeSubject(
            item: libraryItem(
                rawPayload: encodedManga,
                pluginType: .novel,
                isAnime: false
            ),
            installedPluginIDs: ["plugin.exact"]
        )
        mangaAsNovel.viewModel.appear()
        await waitUntil { mangaAsNovel.viewModel.failure == .payloadDecode }
        XCTAssertTrue(mangaAsNovel.plugins.runnerRequests.isEmpty)
        XCTAssertNil(mangaAsNovel.viewModel.route)

        let encodedNovel = try JSONEncoder().encode(Novel(key: "novel", title: "Novel"))
        let novelAsManga = makeSubject(
            item: libraryItem(
                rawPayload: encodedNovel,
                pluginType: .manga,
                isAnime: false
            ),
            installedPluginIDs: ["plugin.exact"]
        )
        novelAsManga.viewModel.appear()
        await waitUntil { novelAsManga.viewModel.failure == .payloadDecode }
        XCTAssertTrue(novelAsManga.plugins.runnerRequests.isEmpty)
        XCTAssertNil(novelAsManga.viewModel.route)
    }

    func testSameIDPluginReplacementInvalidatesReadyAndPendingRunnerWork() async throws {
        let firstRunner = ItoRunner()
        let replacementRunner = ItoRunner()
        let republishedRunner = ItoRunner()
        let ready = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [
                .immediate(.success(firstRunner)),
                .immediate(.success(replacementRunner)),
                .immediate(.success(republishedRunner))
            ]
        )
        ready.viewModel.appear()
        await waitUntil { ready.viewModel.route != nil }
        XCTAssertTrue(ready.viewModel.route?.destination.runner === firstRunner)

        ready.plugins.publish(["plugin.exact"], version: "2.0.0")
        await waitUntil { ready.viewModel.route?.destination.runner === replacementRunner }
        ready.plugins.publish(["plugin.exact"], version: "2.0.0")
        await waitUntil { ready.viewModel.route?.destination.runner === republishedRunner }
        XCTAssertEqual(
            ready.plugins.runnerRequests,
            ["plugin.exact", "plugin.exact", "plugin.exact"]
        )

        let staleRunner = ItoRunner()
        let currentRunner = ItoRunner()
        let pending = try makeSubject(
            item: encodedItem(.manga(Manga(key: "manga", title: "Manga")), pluginType: .manga),
            installedPluginIDs: ["plugin.exact"],
            runnerResponses: [.suspended, .immediate(.success(currentRunner))]
        )
        pending.viewModel.appear()
        await waitUntil { pending.plugins.pendingRunnerCount == 1 }
        pending.plugins.publish(["plugin.exact"], version: "2.0.0")
        await waitUntil { pending.viewModel.route != nil }
        let currentRouteID = pending.viewModel.route?.id
        pending.plugins.resolveRunner(at: 0, result: .success(staleRunner))
        await Task.yield()
        XCTAssertEqual(pending.viewModel.route?.id, currentRouteID)
        XCTAssertTrue(pending.viewModel.route?.destination.runner === currentRunner)
    }

    func testSavedMangaOpensWithoutAnInstalledSourceAndAddsOnlyDownloadedChaptersTheSavedPayloadLacks() async throws {
        let payload = Manga(key: "manga", title: "Manga", chapters: [
            Chapter(key: "c1", chapter: 1),
            Chapter(key: "c2", chapter: 2)
        ])
        let inventory = InventoryOfflineChapterReading(rows: [
            try DownloadedChapterRecord.verifiedFixture(chapterKey: "c2"),
            try DownloadedChapterRecord.verifiedFixture(chapterKey: "c3")
        ])
        let subject = makeSubject(
            item: try encodedItem(.manga(payload), pluginType: .manga),
            offlineReading: inventory
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.canOpenSavedDetails }

        subject.viewModel.openSavedDetails()
        await waitUntil { subject.viewModel.route != nil }

        guard case .manga(let pluginID, let runner, let media)? = subject.viewModel.route?.destination else {
            return XCTFail("The saved series opens as a manga route")
        }
        XCTAssertEqual(pluginID, "plugin.exact")
        XCTAssertNil(runner)
        // c2 is listed by the payload and is not repeated; only the downloaded c3 is added, after c1 and c2.
        XCTAssertEqual(media.chapters?.map(\.key), ["c1", "c2", "c3"])
    }

    func testSavedAnimeHasNoSavedOnlyRoute() async throws {
        let anime = Anime(key: "anime", title: "Anime")
        let subject = makeSubject(
            item: try encodedItem(.anime(anime), pluginType: .anime),
            offlineReading: InventoryOfflineChapterReading(rows: [])
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }

        XCTAssertFalse(subject.viewModel.canOpenSavedDetails)
        subject.viewModel.openSavedDetails()
        XCTAssertNil(subject.viewModel.route)
    }

    func testSavedDetailsAreHiddenWhenOfflineCopiesAreUnavailable() async throws {
        let payload = Manga(key: "manga", title: "Manga", chapters: [Chapter(key: "c1", chapter: 1)])
        let subject = makeSubject(
            item: try encodedItem(.manga(payload), pluginType: .manga),
            offlineReading: InventoryOfflineChapterReading(rows: [], isAvailable: false)
        )
        subject.viewModel.appear()
        await waitUntil { subject.viewModel.isPluginMissing }

        XCTAssertFalse(subject.viewModel.canOpenSavedDetails)
        subject.viewModel.openSavedDetails()
        XCTAssertNil(subject.viewModel.route)
    }

    private func makeSubject(
        item: Ito.LibraryItem,
        installedPluginIDs: Set<String> = [],
        installedPluginKinds: Set<MediaKind>? = nil,
        runnerResponses: [DeferredPluginFake.RunnerResponse] = [],
        lookupResponses: [DeferredInstallerFake.LookupResponse] = [],
        installResponses: [DeferredInstallerFake.InstallResponse] = [],
        decoder: (any DeferredPluginPayloadDecoding)? = nil,
        openIntent: MediaDetailOpenIntent? = nil,
        offlineReading: any OfflineChapterReading = UnavailableOfflineChapterReading()
    ) -> DeferredSubject {
        let plugins = DeferredPluginFake(
            installedPluginIDs: installedPluginIDs,
            supportedKinds: installedPluginKinds ?? [item.effectiveType],
            runnerResponses: runnerResponses
        )
        let installer = DeferredInstallerFake(
            lookupResponses: lookupResponses,
            installResponses: installResponses
        )
        let logger = PresentationEventCaptureSpy()
        let viewModel = DeferredPluginViewModel(
            item: item,
            openIntent: openIntent,
            plugins: plugins,
            installer: installer,
            payloadDecoder: decoder ?? JSONDeferredPluginPayloadDecoder(),
            offlineReading: offlineReading,
            presentationLogger: logger
        )
        return DeferredSubject(
            viewModel: viewModel,
            plugins: plugins,
            installer: installer,
            logger: logger
        )
    }

    private func encodedItem(
        _ media: DeferredPluginMedia,
        pluginType: MediaKind
    ) throws -> Ito.LibraryItem {
        let data: Data
        switch media {
        case .manga(let manga): data = try JSONEncoder().encode(manga)
        case .anime(let anime): data = try JSONEncoder().encode(anime)
        case .novel(let novel): data = try JSONEncoder().encode(novel)
        }
        return libraryItem(
            rawPayload: data,
            pluginType: pluginType,
            isAnime: pluginType == .anime
        )
    }

    private func libraryItem(
        rawPayload: Data,
        pluginType: MediaKind,
        isAnime: Bool
    ) -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: "item.exact",
            title: "Private title",
            coverUrl: nil,
            pluginId: "plugin.exact",
            isAnime: isAnime,
            pluginType: pluginType,
            rawPayload: rawPayload,
            anilistId: nil
        )
    }

    private func candidate(
        isCompatible: Bool = true,
        incompatibility: PluginIncompatibility? = nil,
        minimumVersion: String = "1.0",
        pluginType: MediaKind = .manga,
        kinds: [String]? = nil
    ) -> DeferredPluginPackageCandidate {
        DeferredPluginPackageCandidate(
            package: RepoPackage(
                id: "plugin.exact",
                name: "Exact",
                version: "1.0.0",
                minAppVersion: minimumVersion,
                downloadUrl: "https://invalid.example/plugin",
                iconUrl: nil,
                sha256: "hash",
                pluginType: pluginType.rawValue,
                archived: nil,
                archivedReason: nil,
                archivedDate: nil,
                kinds: kinds
            ),
            repositoryURL: "https://invalid.example/repository",
            incompatibility: incompatibility ?? (isCompatible ? nil : .requiresNewerApp(minimumAppVersion: minimumVersion))
        )
    }

    private func assert(
        destination: DeferredPluginDestination,
        matches expected: DeferredPluginMedia,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (destination, expected) {
        case (.manga(_, _, let actual), .manga(let expected)):
            XCTAssertEqual(actual.key, expected.key, file: file, line: line)
        case (.anime(_, _, let actual), .anime(let expected)):
            XCTAssertEqual(actual.key, expected.key, file: file, line: line)
        case (.novel(_, _, let actual), .novel(let expected)):
            XCTAssertEqual(actual.key, expected.key, file: file, line: line)
        default:
            XCTFail("Unexpected typed destination", file: file, line: line)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private extension DeferredPluginViewModel {
    var failure: DeferredPluginFailure? {
        guard case .failure(let failure) = phase else { return nil }
        return failure
    }

    var isPluginMissing: Bool {
        guard case .pluginMissing = phase else { return false }
        return true
    }

    var isPackageUnavailable: Bool {
        guard case .packageUnavailable = phase else { return false }
        return true
    }

    var incompatibility: PluginIncompatibility? {
        guard case .incompatible(let incompatibility) = phase else { return nil }
        return incompatibility
    }

    var isInstalling: Bool {
        guard case .installing = phase else { return false }
        return true
    }

    var isCancelled: Bool {
        guard case .cancelled = phase else { return false }
        return true
    }
}
