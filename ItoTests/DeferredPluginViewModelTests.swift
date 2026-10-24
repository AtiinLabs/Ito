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

            subject.viewModel.appear()
            await waitUntil { subject.viewModel.route != nil }

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
        await waitUntil { incompatible.viewModel.incompatibleMinimumVersion == "99.0" }
        XCTAssertEqual(incompatible.installer.lookupRequests, ["plugin.exact"])
        XCTAssertTrue(incompatible.installer.installRequests.isEmpty)
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

    private func makeSubject(
        item: Ito.LibraryItem,
        installedPluginIDs: Set<String> = [],
        installedPluginKinds: Set<MediaKind>? = nil,
        runnerResponses: [DeferredPluginFake.RunnerResponse] = [],
        lookupResponses: [DeferredInstallerFake.LookupResponse] = [],
        installResponses: [DeferredInstallerFake.InstallResponse] = [],
        decoder: (any DeferredPluginPayloadDecoding)? = nil
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
            plugins: plugins,
            installer: installer,
            payloadDecoder: decoder ?? JSONDeferredPluginPayloadDecoder(),
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
            incompatibility: isCompatible ? nil : PluginRequiresNewerAppError(minimumAppVersion: minimumVersion)
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

    var incompatibleMinimumVersion: String? {
        guard case .incompatible(let version) = phase else { return nil }
        return version
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

private struct DeferredSubject {
    let viewModel: DeferredPluginViewModel
    let plugins: DeferredPluginFake
    let installer: DeferredInstallerFake
    let logger: PresentationEventCaptureSpy
}

private enum DeferredTestFailure: Error {
    case expected
}

@MainActor
private final class DeferredPluginFake: LibraryPluginServing {
    enum RunnerResponse {
        case immediate(Result<ItoRunner, Error>)
        case suspended
    }

    private let subject: CurrentValueSubject<LibraryPluginSnapshot, Never>
    private let defaultKinds: Set<MediaKind>
    private var runnerResponses: [RunnerResponse]
    private var runnerContinuations: [CheckedContinuation<ItoRunner, Error>] = []
    private(set) var runnerRequests: [String] = []

    init(
        installedPluginIDs: Set<String>,
        supportedKinds: Set<MediaKind>,
        runnerResponses: [RunnerResponse]
    ) {
        self.defaultKinds = supportedKinds
        subject = CurrentValueSubject(
            LibraryPluginSnapshot(
                publicationRevision: 0,
                plugins: Self.identities(
                    for: installedPluginIDs,
                    supportedKinds: supportedKinds,
                    version: "1.0.0"
                )
            )
        )
        self.runnerResponses = runnerResponses
    }

    var libraryPluginSnapshot: LibraryPluginSnapshot { subject.value }
    var libraryPluginSnapshotPublisher: AnyPublisher<LibraryPluginSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }
    var pendingRunnerCount: Int { runnerContinuations.count }

    func publish(
        _ pluginIDs: Set<String>,
        supportedKinds: Set<MediaKind>? = nil,
        version: String = "1.0.0"
    ) {
        subject.send(
            LibraryPluginSnapshot(
                publicationRevision: subject.value.publicationRevision &+ 1,
                plugins: Self.identities(
                    for: pluginIDs,
                    supportedKinds: supportedKinds ?? defaultKinds,
                    version: version
                )
            )
        )
    }

    func libraryRunner(
        for plugin: LibraryInstalledPluginIdentity,
        publicationRevision: UInt64
    ) async throws -> ItoRunner {
        runnerRequests.append(plugin.id)
        guard subject.value.publicationRevision == publicationRevision,
              subject.value.plugins[plugin.id] == plugin else {
            throw DeferredTestFailure.expected
        }
        guard !runnerResponses.isEmpty else { throw DeferredTestFailure.expected }
        switch runnerResponses.removeFirst() {
        case .immediate(let result): return try result.get()
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                runnerContinuations.append(continuation)
            }
        }
    }

    func resolveRunner(at index: Int, result: Result<ItoRunner, Error>) {
        runnerContinuations.remove(at: index).resume(with: result)
    }

    private static func identities(
        for pluginIDs: Set<String>,
        supportedKinds: Set<MediaKind>,
        version: String
    ) -> [String: LibraryInstalledPluginIdentity] {
        Dictionary(uniqueKeysWithValues: pluginIDs.map { pluginID in
            (
                pluginID,
                LibraryInstalledPluginIdentity(
                    id: pluginID,
                    version: version,
                    supportedKinds: supportedKinds,
                    fileIdentity: URL(fileURLWithPath: "/test/\(pluginID).ito")
                )
            )
        })
    }
}

@MainActor
private final class DeferredInstallerFake: DeferredPluginInstalling {
    enum LookupResponse {
        case immediate(DeferredPluginPackageCandidate?)
        case failure(Error)
        case suspended
    }

    enum InstallResponse {
        case immediate(Result<Void, Error>)
        case suspended
    }

    private var lookupResponses: [LookupResponse]
    private var installResponses: [InstallResponse]
    private var lookupContinuations: [CheckedContinuation<DeferredPluginPackageCandidate?, Error>] = []
    private var installContinuations: [CheckedContinuation<Void, Error>] = []
    private(set) var lookupRequests: [String] = []
    private(set) var installRequests: [DeferredPluginPackageCandidate] = []
    var onInstallSuspended: (() -> Void)?

    init(
        lookupResponses: [LookupResponse],
        installResponses: [InstallResponse]
    ) {
        self.lookupResponses = lookupResponses
        self.installResponses = installResponses
    }

    var pendingLookupCount: Int { lookupContinuations.count }
    var pendingInstallCount: Int { installContinuations.count }

    func findPackage(forExactPluginID pluginID: String) async throws
        -> DeferredPluginPackageCandidate? {
        lookupRequests.append(pluginID)
        guard !lookupResponses.isEmpty else { return nil }
        switch lookupResponses.removeFirst() {
        case .immediate(let candidate): return candidate
        case .failure(let error): throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                lookupContinuations.append(continuation)
            }
        }
    }

    func install(_ candidate: DeferredPluginPackageCandidate) async throws {
        installRequests.append(candidate)
        guard !installResponses.isEmpty else { throw DeferredTestFailure.expected }
        switch installResponses.removeFirst() {
        case .immediate(let result): try result.get()
        case .suspended:
            try await withCheckedThrowingContinuation { continuation in
                installContinuations.append(continuation)
                onInstallSuspended?()
            }
        }
    }

    func resolveLookup(at index: Int, candidate: DeferredPluginPackageCandidate?) {
        lookupContinuations.remove(at: index).resume(returning: candidate)
    }

    func resolveLookup(
        at index: Int,
        result: Result<DeferredPluginPackageCandidate?, Error>
    ) {
        lookupContinuations.remove(at: index).resume(with: result)
    }

    func resolveInstall(at index: Int, result: Result<Void, Error>) {
        installContinuations.remove(at: index).resume(with: result)
    }
}

@MainActor
private final class DeferredDecoderFake: DeferredPluginPayloadDecoding {
    enum Response {
        case immediate(Result<DeferredPluginMedia, Error>)
        case suspended
    }

    private var responses: [Response]
    private var continuations: [CheckedContinuation<DeferredPluginMedia, Error>] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var pendingCount: Int { continuations.count }

    func decode(_ item: Ito.LibraryItem) async throws -> DeferredPluginMedia {
        _ = item
        guard !responses.isEmpty else { throw DeferredTestFailure.expected }
        switch responses.removeFirst() {
        case .immediate(let result): return try result.get()
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    func resolve(at index: Int, result: Result<DeferredPluginMedia, Error>) {
        continuations.remove(at: index).resume(with: result)
    }
}
