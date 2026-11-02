import Combine
import XCTest
@testable import Ito

@MainActor
final class TrackerDetailsViewModelTests: XCTestCase {
    func testInitialLoadExistingEntryPopulatesCharacterizedFields() async {
        let startDate = Date(timeIntervalSince1970: 100)
        let finishDate = Date(timeIntervalSince1970: 200)
        let entry = TrackerMediaEntry(
            status: "COMPLETED",
            progress: 12,
            score: 8.5,
            startDate: startDate,
            finishDate: finishDate
        )
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(entry)]
        let viewModel = makeViewModel(service: service)

        XCTAssertEqual(viewModel.remoteEntryState, .loading)
        viewModel.start()
        viewModel.start()
        await trackingWaitUntil { viewModel.remoteEntryState == .existing }

        XCTAssertEqual(service.loadInvocations.count, 1)
        XCTAssertEqual(service.loadInvocations[0].providerID, "anilist")
        XCTAssertEqual(service.loadInvocations[0].mediaID, "remote-1")
        XCTAssertEqual(viewModel.status, "COMPLETED")
        XCTAssertEqual(viewModel.progress, "12")
        XCTAssertEqual(viewModel.score, 8.5)
        XCTAssertEqual(viewModel.startDate, startDate)
        XCTAssertEqual(viewModel.finishDate, finishDate)
    }

    func testNoRemoteEntryAndRemoteFailureRemainDistinctAndRetryable() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [
            .failure(TrackingTestError.failure),
            .success(nil)
        ]
        let viewModel = makeViewModel(service: service)

        viewModel.start()
        await trackingWaitUntil { viewModel.remoteEntryState == .failure }
        XCTAssertNotNil(viewModel.remoteLoadErrorMessage)
        viewModel.save()
        XCTAssertTrue(service.updateInvocations.isEmpty)

        viewModel.retryRemoteEntryLoad()
        await trackingWaitUntil { viewModel.remoteEntryState == .new }
        XCTAssertNil(viewModel.remoteLoadErrorMessage)
        XCTAssertEqual(viewModel.status, "PLANNING")
        XCTAssertEqual(viewModel.progress, "0")
        XCTAssertEqual(service.loadInvocations.count, 2)
    }

    func testStaleLoadCannotOverwriteNewerEntryState() async {
        let service = TrackerDetailsServiceFake()
        service.suspendsLoads = true
        let viewModel = makeViewModel(service: service)

        viewModel.start()
        await trackingWaitUntil { service.pendingLoadCount == 1 }
        viewModel.retryRemoteEntryLoad()
        await trackingWaitUntil { service.pendingLoadCount == 2 }

        service.completeLoad(at: 1, with: .success(nil))
        await trackingWaitUntil { viewModel.remoteEntryState == .new }
        service.completeLoad(
            with: .success(
                TrackerMediaEntry(
                    status: "COMPLETED",
                    progress: 99,
                    score: 10,
                    startDate: nil,
                    finishDate: nil
                )
            )
        )
        await Task.yield()

        XCTAssertEqual(viewModel.remoteEntryState, .new)
        XCTAssertEqual(viewModel.status, "PLANNING")
        XCTAssertEqual(viewModel.progress, "0")
    }

    func testStatusLabelsTotalsAndProgressEditingAreDeterministic() {
        let manga = makeViewModel(media: trackerTestMedia(format: "MANGA", chapters: 12))
        let novel = makeViewModel(media: trackerTestMedia(format: "NOVEL", chapters: 14))
        let oneShot = makeViewModel(media: trackerTestMedia(format: "ONE_SHOT", chapters: 1))
        let anime = makeViewModel(
            media: trackerTestMedia(format: "TV", episodes: 24, chapters: nil)
        )

        XCTAssertEqual(
            TrackerDetailsViewModel.statuses,
            ["CURRENT", "PLANNING", "COMPLETED", "DROPPED", "PAUSED", "REPEATING"]
        )
        XCTAssertEqual(manga.currentStatusLabel, "Reading")
        XCTAssertEqual(novel.currentStatusLabel, "Reading")
        XCTAssertEqual(oneShot.displayLabel(for: "CURRENT"), "Reading")
        XCTAssertEqual(anime.currentStatusLabel, "Watching")
        XCTAssertEqual(manga.totalProgress, 12)
        XCTAssertEqual(anime.totalProgress, 24)

        manga.decrementProgress()
        XCTAssertEqual(manga.progress, "0")
        manga.incrementProgress()
        XCTAssertEqual(manga.progress, "1")
        XCTAssertEqual(manga.status, "CURRENT")
        manga.decrementProgress()
        manga.decrementProgress()
        XCTAssertEqual(manga.progress, "0")
        manga.progress = "not-a-number"
        manga.incrementProgress()
        XCTAssertEqual(manga.progress, "not-a-number")
    }

    func testLocalHistorySyncUsesExactMediaMaximumAndRequiresConfirmation() {
        let progress = TrackerLocalProgressReaderFake(progress: [1.2, 7.9, 4])
        let viewModel = makeViewModel(progress: progress)

        viewModel.prepareLocalProgressSync()
        XCTAssertEqual(progress.mediaRequests, [viewModel.mediaIdentity])
        XCTAssertEqual(viewModel.localProgressCandidate, .found(7))
        XCTAssertTrue(viewModel.isPresentingLocalProgressAlert)
        XCTAssertEqual(viewModel.progress, "0")

        viewModel.cancelLocalProgressSync()
        XCTAssertEqual(viewModel.progress, "0")
        XCTAssertNil(viewModel.localProgressCandidate)

        viewModel.prepareLocalProgressSync()
        viewModel.confirmLocalProgressSync()
        XCTAssertEqual(viewModel.progress, "7")
        XCTAssertEqual(viewModel.status, "CURRENT")
        XCTAssertNil(viewModel.localProgressCandidate)
    }

    func testNoLocalHistoryIsDistinctAndDoesNotMutateProgress() {
        let viewModel = makeViewModel(progress: TrackerLocalProgressReaderFake())
        viewModel.progress = "3"

        viewModel.prepareLocalProgressSync()
        XCTAssertEqual(viewModel.localProgressCandidate, .notFound)
        viewModel.confirmLocalProgressSync()

        XCTAssertEqual(viewModel.progress, "3")
        XCTAssertNil(viewModel.localProgressCandidate)
    }

    func testExternalURLUsesInjectedBoundaryAndFailureIsDeterministic() async {
        let opener = TrackerExternalURLOpenerFake()
        let messages = TrackingMessageCaptureSpy()
        let viewModel = makeViewModel(opener: opener, messages: messages)

        viewModel.openExternalURL()
        await trackingWaitUntil { !viewModel.isOpeningExternalURL }
        XCTAssertEqual(opener.invocations.count, 1)
        XCTAssertEqual(opener.invocations[0].providerID, "anilist")
        XCTAssertEqual(opener.invocations[0].media, viewModel.media)

        opener.error = TrackingTestError.failure
        viewModel.openExternalURL()
        await trackingWaitUntil { !viewModel.isOpeningExternalURL }
        XCTAssertEqual(messages.messages, [.externalURLOpenFailed])
    }

    func testExistingLinkedSaveSendsOnlyProgressAndStatusAndDoesNotDuplicateLink() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(nil)]
        let links = TrackerLinkStoreFake()
        let viewModel = makeViewModel(service: service, links: links, isLinked: true)
        await load(viewModel, state: .new)
        viewModel.progress = "4"
        viewModel.status = "PAUSED"

        viewModel.save()
        await trackingWaitUntil { !viewModel.isSaving }

        XCTAssertEqual(
            service.updateInvocations,
            [.init(providerID: "anilist", mediaID: "remote-1", progress: 4, status: "PAUSED")]
        )
        XCTAssertTrue(links.linkInvocations.isEmpty)
        XCTAssertEqual(viewModel.output?.kind, .saved(progress: 4, status: "PAUSED"))
        XCTAssertEqual(viewModel.consumeOutput()?.kind, .saved(progress: 4, status: "PAUSED"))
        XCTAssertNil(viewModel.output)
    }

    func testNewEntrySaveRequiresRemoteThenDurableLocalLinkBeforeSuccess() async {
        let journal = TrackingCallJournal()
        let service = TrackerDetailsServiceFake(journal: journal)
        service.queuedLoadResults = [.success(nil)]
        service.suspendsUpdates = true
        let links = TrackerLinkStoreFake(journal: journal)
        links.suspendsLinks = true
        let viewModel = makeViewModel(service: service, links: links)
        await load(viewModel, state: .new)

        viewModel.save()
        await trackingWaitUntil { service.pendingUpdateCount == 1 }
        XCTAssertEqual(journal.events.suffix(1), ["update"])
        XCTAssertTrue(links.linkInvocations.isEmpty)
        XCTAssertNil(viewModel.output)

        service.completeUpdate(with: .success(()))
        await trackingWaitUntil { links.pendingLinkCount == 1 }
        XCTAssertEqual(journal.events.suffix(2), ["update", "link"])
        XCTAssertNil(viewModel.output)

        links.completeLink(with: .success(()))
        await trackingWaitUntil { !viewModel.isSaving }
        XCTAssertTrue(viewModel.isLocallyLinked)
        XCTAssertEqual(viewModel.output?.kind, .saved(progress: 0, status: "PLANNING"))
    }

    func testRemoteUpdateFailureNeverLinksReportsSuccessOrDismisses() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(nil)]
        service.queuedUpdateResults = [.failure(TrackingTestError.failure)]
        let links = TrackerLinkStoreFake()
        let messages = TrackingMessageCaptureSpy()
        let viewModel = makeViewModel(service: service, links: links, messages: messages)
        await load(viewModel, state: .new)

        viewModel.save()
        await trackingWaitUntil { !viewModel.isSaving }

        XCTAssertEqual(viewModel.failure, .remoteUpdate)
        XCTAssertTrue(viewModel.isPresentingFailureAlert)
        XCTAssertTrue(links.linkInvocations.isEmpty)
        XCTAssertNil(viewModel.output)
        XCTAssertFalse(viewModel.isLocallyLinked)
        XCTAssertEqual(messages.messages, [.remoteUpdateFailed])
    }

    func testLocalLinkFailureReportsPartialTruthAndRemainsRetryable() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(nil)]
        let links = TrackerLinkStoreFake()
        links.linkError = TrackingTestError.failure
        let messages = TrackingMessageCaptureSpy()
        let viewModel = makeViewModel(service: service, links: links, messages: messages)
        await load(viewModel, state: .new)

        viewModel.save()
        await trackingWaitUntil { !viewModel.isSaving }
        XCTAssertEqual(viewModel.failure, .linkPersistenceAfterRemoteUpdate)
        XCTAssertNil(viewModel.output)
        XCTAssertFalse(viewModel.isLocallyLinked)
        XCTAssertEqual(messages.messages, [.linkPersistenceFailed])

        viewModel.dismissFailure()
        links.linkError = nil
        viewModel.save()
        await trackingWaitUntil { !viewModel.isSaving }
        XCTAssertEqual(service.updateInvocations.count, 2)
        XCTAssertEqual(links.linkInvocations.count, 2)
        XCTAssertTrue(viewModel.isLocallyLinked)
        XCTAssertEqual(viewModel.output?.kind, .saved(progress: 0, status: "PLANNING"))
    }

    func testDuplicateAndStaleSaveCompletionsCannotAffectNewerSave() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(nil)]
        service.suspendsUpdates = true
        let links = TrackerLinkStoreFake()
        let viewModel = makeViewModel(service: service, links: links)
        await load(viewModel, state: .new)

        viewModel.save()
        viewModel.save()
        await trackingWaitUntil { service.pendingUpdateCount == 1 }
        XCTAssertEqual(service.updateInvocations.count, 1)

        viewModel.cancelOwnedWork()
        viewModel.save()
        await trackingWaitUntil { service.pendingUpdateCount == 2 }
        service.completeUpdate(at: 0, with: .success(()))
        await Task.yield()
        XCTAssertTrue(viewModel.isSaving)
        XCTAssertTrue(links.linkInvocations.isEmpty)
        XCTAssertNil(viewModel.output)

        service.completeUpdate(with: .success(()))
        await trackingWaitUntil { !viewModel.isSaving }
        XCTAssertEqual(links.linkInvocations.count, 1)
        XCTAssertEqual(viewModel.output?.kind, .saved(progress: 0, status: "PLANNING"))
    }

    func testStopTrackingRequiresDurableUnlinkAndSuppressesDuplicates() async {
        let links = TrackerLinkStoreFake()
        links.suspendsUnlinks = true
        let viewModel = makeViewModel(links: links, isLinked: true)

        viewModel.stopTracking()
        viewModel.stopTracking()
        await trackingWaitUntil { links.pendingUnlinkCount == 1 }
        XCTAssertEqual(links.unlinkInvocations.count, 1)
        XCTAssertNil(viewModel.output)
        XCTAssertTrue(viewModel.isLocallyLinked)

        links.completeUnlink(with: .success(()))
        await trackingWaitUntil { !viewModel.isUnlinking }
        XCTAssertFalse(viewModel.isLocallyLinked)
        XCTAssertEqual(viewModel.output?.kind, .unlinked)
    }

    func testUnlinkFailurePreservesAuthoritativeLinkAndNeverEmitsSuccess() async {
        let links = TrackerLinkStoreFake()
        links.unlinkError = TrackingTestError.failure
        let messages = TrackingMessageCaptureSpy()
        let viewModel = makeViewModel(links: links, messages: messages, isLinked: true)

        viewModel.stopTracking()
        await trackingWaitUntil { !viewModel.isUnlinking }

        XCTAssertEqual(viewModel.failure, .unlinkPersistence)
        XCTAssertTrue(viewModel.isLocallyLinked)
        XCTAssertNil(viewModel.output)
        XCTAssertEqual(messages.messages, [.unlinkFailed])
    }

    func testStaleUnlinkCompletionCannotClearNewerUnlinkStateOrEmitSuccess() async {
        let links = TrackerLinkStoreFake()
        links.suspendsUnlinks = true
        let viewModel = makeViewModel(links: links, isLinked: true)

        viewModel.stopTracking()
        await trackingWaitUntil { links.pendingUnlinkCount == 1 }
        viewModel.cancelOwnedWork()
        viewModel.stopTracking()
        await trackingWaitUntil { links.pendingUnlinkCount == 2 }

        links.completeUnlink(at: 0, with: .failure(TrackingTestError.failure))
        await Task.yield()
        XCTAssertTrue(viewModel.isUnlinking)
        XCTAssertTrue(viewModel.isLocallyLinked)
        XCTAssertNil(viewModel.failure)
        XCTAssertNil(viewModel.output)

        links.completeUnlink(with: .success(()))
        await trackingWaitUntil { !viewModel.isUnlinking }
        XCTAssertFalse(viewModel.isLocallyLinked)
        XCTAssertEqual(viewModel.output?.kind, .unlinked)
    }

    func testCancelEmitsOnlyWhenNoDurableOperationIsRunning() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(nil)]
        service.suspendsUpdates = true
        let viewModel = makeViewModel(service: service, showCancel: true)
        await load(viewModel, state: .new)

        viewModel.cancel()
        XCTAssertEqual(viewModel.consumeOutput()?.kind, .cancelled)

        viewModel.save()
        await trackingWaitUntil { service.pendingUpdateCount == 1 }
        viewModel.cancel()
        XCTAssertNil(viewModel.output)
        service.completeUpdate(with: .success(()))
        await trackingWaitUntil { !viewModel.isSaving }
        XCTAssertEqual(viewModel.output?.kind, .saved(progress: 0, status: "PLANNING"))
    }

    private func load(
        _ viewModel: TrackerDetailsViewModel,
        state: TrackerRemoteEntryPresentationState
    ) async {
        viewModel.start()
        await trackingWaitUntil { viewModel.remoteEntryState == state }
    }

    private func makeViewModel(
        media: TrackerMedia = trackerTestMedia(),
        service: TrackerDetailsServiceFake = TrackerDetailsServiceFake(),
        links: TrackerLinkStoreFake = TrackerLinkStoreFake(),
        progress: TrackerLocalProgressReaderFake = TrackerLocalProgressReaderFake(),
        opener: TrackerExternalURLOpenerFake = TrackerExternalURLOpenerFake(),
        messages: TrackingMessageCaptureSpy = TrackingMessageCaptureSpy(),
        logger: PresentationEventCaptureSpy = PresentationEventCaptureSpy(),
        isLinked: Bool = false,
        showCancel: Bool = false,
        providerID: String = "anilist",
        providerName: String = "AniList"
    ) -> TrackerDetailsViewModel {
        links.scoreSessionValidator = { providerID, session in
            try service.validateScoreSession(providerID: providerID, scoreSession: session)
        }
        return TrackerDetailsViewModel(
            destination: trackerTestDestination(
                media: media,
                isLocallyLinked: isLinked,
                showCancelButton: showCancel,
                providerID: providerID,
                providerName: providerName
            ),
            detailsService: service,
            linkStore: links,
            localProgressReader: progress,
            externalURLOpener: opener,
            messagePresenter: messages,
            presentationLogger: logger
        )
    }

    private func automaticSyncNote(providerID: String, status: String) async -> String? {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(TrackerMediaEntry(status: status, progress: 3, score: nil, startDate: nil, finishDate: nil))]
        let isMangaBaka = providerID == "mangabaka"
        let viewModel = makeViewModel(
            media: trackerTestMedia(
                id: providerID == "myanimelist" ? "anime:1" : isMangaBaka ? "42" : "remote-1",
                format: isMangaBaka ? "MANGA" : "TV"
            ),
            service: service,
            isLinked: true,
            providerID: providerID,
            providerName: providerID == "myanimelist" ? "MyAnimeList" : isMangaBaka ? "MangaBaka" : "AniList"
        )
        await load(viewModel, state: .existing)
        return viewModel.automaticSyncNote
    }

    func testLoadingAPlannedEntryWithProgressKeepsItPlanned() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(TrackerMediaEntry(status: "PLANNING", progress: 3, score: nil, startDate: nil, finishDate: nil))]
        let viewModel = makeViewModel(
            media: trackerTestMedia(id: "42", format: "MANGA"),
            service: service,
            isLinked: true,
            providerID: "mangabaka",
            providerName: "MangaBaka"
        )
        await load(viewModel, state: .existing)

        XCTAssertEqual(viewModel.status, "PLANNING")
        XCTAssertEqual(viewModel.progress, "3")

        viewModel.save()
        await trackingWaitUntil { !viewModel.isSaving }
        XCTAssertEqual(
            service.updateInvocations,
            [.init(providerID: "mangabaka", mediaID: "42", progress: 3, status: "PLANNING")]
        )
    }

    func testTrackerExplanationReplacesTheGenericLoadFailure() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.failure(MangaBakaTrackerError.seriesMerged(into: 1995))]
        let viewModel = makeViewModel(
            media: trackerTestMedia(id: "42", format: "MANGA"),
            service: service,
            isLinked: true,
            providerID: "mangabaka",
            providerName: "MangaBaka"
        )
        await load(viewModel, state: .failure)

        XCTAssertEqual(
            viewModel.remoteLoadErrorMessage,
            "MangaBaka merged this series into series 1995. Stop tracking it and link it again."
        )
    }

    func testForwardOnlyTrackersRefuseToLowerProgressUnlessRepeating() async {
        let trackers = [
            (id: "myanimelist", name: "MyAnimeList", mediaID: "anime:1", format: "TV"),
            (id: "mangabaka", name: "MangaBaka", mediaID: "42", format: "MANHWA")
        ]
        for tracker in trackers {
            let service = TrackerDetailsServiceFake()
            service.queuedLoadResults = [.success(TrackerMediaEntry(status: "CURRENT", progress: 10, score: nil, startDate: nil, finishDate: nil))]
            let viewModel = makeViewModel(
                media: trackerTestMedia(id: tracker.mediaID, format: tracker.format),
                service: service,
                isLinked: true,
                providerID: tracker.id,
                providerName: tracker.name
            )
            await load(viewModel, state: .existing)
            viewModel.progress = "4"

            viewModel.save()

            XCTAssertTrue(service.updateInvocations.isEmpty, tracker.id)
            XCTAssertEqual(viewModel.failure, .progressWouldDecrease(providerName: tracker.name))
            XCTAssertTrue(viewModel.isPresentingFailureAlert)
            XCTAssertNil(viewModel.output)

            viewModel.status = "REPEATING"
            viewModel.save()
            await trackingWaitUntil { !viewModel.isSaving }
            XCTAssertEqual(
                service.updateInvocations,
                [.init(providerID: tracker.id, mediaID: tracker.mediaID, progress: 4, status: "REPEATING")]
            )
        }
    }

    func testAniListStillLetsProgressGoDown() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(TrackerMediaEntry(status: "CURRENT", progress: 10, score: nil, startDate: nil, finishDate: nil))]
        let viewModel = makeViewModel(service: service, isLinked: true)
        await load(viewModel, state: .existing)
        viewModel.progress = "4"

        viewModel.save()
        await trackingWaitUntil { !viewModel.isSaving }

        XCTAssertEqual(
            service.updateInvocations,
            [.init(providerID: "anilist", mediaID: "remote-1", progress: 4, status: "CURRENT")]
        )
        XCTAssertNil(viewModel.failure)
    }

    func testAutomaticSyncNoteExplainsMyAnimeListStatuses() async {
        let completed = await automaticSyncNote(providerID: "myanimelist", status: "COMPLETED")
        XCTAssertEqual(
            completed,
            "Automatic progress updates are off while this entry is Completed. Set it to Watching to resume them."
        )
        let planned = await automaticSyncNote(providerID: "myanimelist", status: "PLANNING")
        XCTAssertEqual(planned, "Ito marks this entry Watching when you start episode 1.")
        let watching = await automaticSyncNote(providerID: "myanimelist", status: "CURRENT")
        XCTAssertNil(watching)
        let anilist = await automaticSyncNote(providerID: "anilist", status: "COMPLETED")
        XCTAssertNil(anilist)
        let mangaBaka = await automaticSyncNote(providerID: "mangabaka", status: "PAUSED")
        XCTAssertEqual(
            mangaBaka,
            "Automatic progress updates are off while this entry is Paused. Set it to Reading to resume them."
        )
    }
}

extension TrackerDetailsViewModelTests {
    func testManualScoreChangesAndClearingDoNotReplayLoadedProgress() async {
        let service = scoringService()
        let model = makeViewModel(service: service, isLinked: true)
        await loadScoring(model)
        model.setScore(8.5)
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations, [
            .init(providerID: "anilist", mediaID: "remote-1", progress: nil, status: nil, score: 8.5)
        ])
        model.setScore(0)
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations.last?.score, 0)
        XCTAssertNil(model.score)
        let writes = service.updateInvocations.count
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations.count, writes)
    }

    func testAnUnchangedScoreIsOmittedWhenProgressIsEdited() async {
        let service = scoringService()
        let model = makeViewModel(service: service, isLinked: true)
        await loadScoring(model)
        model.progress = "13"
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations, [
            .init(providerID: "anilist", mediaID: "remote-1", progress: 13, status: nil, score: nil)
        ])
    }

    func testOtherNativeTrackerRatingsEditAndClearWithoutChangingProgressOrStatus() async {
        let providers: [(id: String, format: TrackerScoreFormat, loaded: Double, selected: Double)] = [
            ("myanimelist", .point10, 7, 9),
            ("mangabaka", .numeric100, 85.5, 90.5)
        ]
        for provider in providers {
            let service = scoringService()
            service.scoreFormat = provider.format
            service.queuedLoadResults = [.success(TrackerMediaEntry(
                status: "CURRENT", progress: 12, score: provider.loaded, startDate: nil, finishDate: nil
            ))]
            let model = makeViewModel(service: service, isLinked: true, providerID: provider.id)
            await loadScoring(model)
            XCTAssertEqual(model.score, provider.loaded)
            await saveScoring(model)
            XCTAssertTrue(service.updateInvocations.isEmpty)
            model.setScore(provider.selected)
            await saveScoring(model)
            XCTAssertEqual(service.updateInvocations, [
                .init(providerID: provider.id, mediaID: "remote-1", progress: nil, status: nil, score: provider.selected)
            ])
            model.setScore(0)
            await saveScoring(model)
            XCTAssertEqual(service.updateInvocations.last?.score, 0)
            XCTAssertNil(service.updateInvocations.last?.progress)
            XCTAssertNil(service.updateInvocations.last?.status)
        }
    }

    func testNumericRatingDraftRejectsInvalidTextWithoutSavingAnOldValue() async {
        let service = scoringService()
        service.scoreFormat = .numeric100
        service.queuedLoadResults = [.success(TrackerMediaEntry(
            status: "CURRENT", progress: 12, score: 85.5, startDate: nil, finishDate: nil
        ))]
        let model = makeViewModel(service: service, isLinked: true, providerID: "mangabaka")
        await loadScoring(model)
        for invalid in ["", "101", "-1", "NaN", "85oops", "1.2.3"] {
            model.scoreInput = invalid
            XCTAssertFalse(model.isScoreInputValid)
            model.save()
            XCTAssertFalse(model.isSaving)
            XCTAssertTrue(service.updateInvocations.isEmpty)
        }
        model.scoreInput = TrackerScoreFormat.numericStyle.format(90.5)
        XCTAssertTrue(model.isScoreInputValid)
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations.last?.score, 90.5)
        XCTAssertNil(service.updateInvocations.last?.progress)
        XCTAssertNil(service.updateInvocations.last?.status)
    }

    func testClearingATinyNumericRatingIsNotSuppressed() async {
        let service = scoringService()
        service.scoreFormat = .numeric100
        service.queuedLoadResults = [.success(TrackerMediaEntry(
            status: "CURRENT", progress: 12, score: 0.000_000_5, startDate: nil, finishDate: nil
        ))]
        let model = makeViewModel(service: service, isLinked: true, providerID: "mangabaka")
        await loadScoring(model)
        model.setScore(0)
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations, [
            .init(providerID: "mangabaka", mediaID: "remote-1", progress: nil, status: nil, score: 0)
        ])
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations.count, 1)
    }

    func testSubEpsilonNumericRatingChangesAreSubmittedExactly() async {
        let service = scoringService()
        service.scoreFormat = .numeric100
        service.queuedLoadResults = [.success(TrackerMediaEntry(
            status: "CURRENT", progress: 12, score: 85.5, startDate: nil, finishDate: nil
        ))]
        let model = makeViewModel(service: service, isLinked: true, providerID: "mangabaka")
        await loadScoring(model)
        let selected = 85.500_000_5
        model.setScore(selected)
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations, [
            .init(providerID: "mangabaka", mediaID: "remote-1", progress: nil, status: nil, score: selected)
        ])
    }

    func testUnknownScoreSettingsFailClosedAndRetryLoadsTheRealFormat() async {
        let service = scoringService()
        service.scoreFormatError = TrackingTestError.failure
        let model = makeViewModel(service: service, isLinked: true)
        await loadScoring(model, state: .failure)
        model.setScore(8)
        model.save()
        XCTAssertNil(model.scoreFormat)
        XCTAssertTrue(service.updateInvocations.isEmpty)
        service.scoreFormatError = nil
        let loaded = expectation(description: "Score format recovered")
        let token = model.$remoteEntryState.filter { $0 == .existing }.sink { _ in loaded.fulfill() }
        model.retryRemoteEntryLoad()
        await fulfillment(of: [loaded], timeout: 2)
        token.cancel()
        XCTAssertEqual(model.scoreFormat, .point10Decimal)
        XCTAssertEqual(model.score, 7)
    }

    func testLinkRetryDoesNotRepeatAcknowledgedScoreOrStaleProgress() async {
        let service = scoringService()
        let links = TrackerLinkStoreFake()
        links.linkError = TrackingTestError.failure
        let model = makeViewModel(service: service, links: links)
        await loadScoring(model)
        model.setScore(8)
        await saveScoring(model)
        XCTAssertEqual(model.failure, .linkPersistenceAfterRemoteUpdate)
        XCTAssertNil(model.output)
        links.linkError = nil
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations.count, 1)
        XCTAssertEqual(links.linkInvocations.count, 2)
        XCTAssertEqual(model.output?.kind, .saved(progress: 12, status: "CURRENT"))
    }

    func testScoreWriteFailureRetainsTheDraftForRetry() async {
        let service = scoringService()
        service.queuedUpdateResults = [.failure(TrackingTestError.failure), .success(())]
        let model = makeViewModel(service: service, isLinked: true)
        await loadScoring(model)
        model.setScore(8.5)
        await saveScoring(model)
        XCTAssertEqual(model.failure, .remoteUpdate)
        XCTAssertNil(model.output)
        XCTAssertEqual(model.score, 8.5)
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations.map(\.score), [8.5, 8.5])
        XCTAssertNotNil(model.output)
    }

    func testCreatedRemoteEntryIsExistingBeforeRetryingFailedLocalLink() async {
        let service = scoringService()
        service.queuedLoadResults = [.success(nil)]
        let links = TrackerLinkStoreFake()
        links.linkError = TrackingTestError.failure
        let model = makeViewModel(service: service, links: links)
        await loadScoring(model, state: .new)
        model.setScore(8)
        await saveScoring(model)
        XCTAssertEqual(model.remoteEntryState, .existing)
        XCTAssertEqual(model.failure, .linkPersistenceAfterRemoteUpdate)
        links.linkError = nil
        await saveScoring(model)
        XCTAssertEqual(service.updateInvocations.count, 1)
        XCTAssertEqual(links.linkInvocations.count, 2)
        XCTAssertEqual(model.output?.kind, .saved(progress: 0, status: "PLANNING"))
    }

    func testAccountSwitchRejectsDraftEvenWithTheSameScoreFormat() async {
        let service = scoringService()
        let links = TrackerLinkStoreFake()
        let model = makeViewModel(service: service, links: links)
        await loadScoring(model)
        model.setScore(8)
        service.scoreIdentity = UUID()
        await saveScoring(model)
        XCTAssertTrue(service.updateInvocations.isEmpty)
        XCTAssertTrue(links.linkInvocations.isEmpty)
        XCTAssertNil(model.output)
        XCTAssertEqual(model.failure, .remoteUpdateExplanation(TrackerScoreEditingError.accountChanged.userMessage))
    }

    func testAccountSwitchDuringEntryLoadShowsRecoverableFailure() async {
        let service = scoringService()
        service.suspendsLoads = true
        let started = expectation(description: "Entry request suspended")
        service.onLoadStarted = { started.fulfill() }
        let model = makeViewModel(service: service)
        let failed = expectation(description: "Stale account response rejected")
        let token = model.$remoteEntryState.filter { $0 == .failure }.sink { _ in failed.fulfill() }
        model.start()
        await fulfillment(of: [started], timeout: 2)
        service.scoreIdentity = UUID()
        service.completeLoad(with: .success(TrackerMediaEntry(
            status: "CURRENT", progress: 99, score: 9, startDate: nil, finishDate: nil
        )))
        await fulfillment(of: [failed], timeout: 2)
        token.cancel()
        XCTAssertNil(model.scoreFormat)
        XCTAssertNil(model.score)
        XCTAssertEqual(model.remoteLoadErrorMessage, TrackerScoreEditingError.accountChanged.userMessage)
    }

    func testAccountSwitchDuringSaveCannotLinkOrPublishSuccess() async {
        let service = scoringService()
        service.suspendsUpdates = true
        let links = TrackerLinkStoreFake()
        let model = makeViewModel(service: service, links: links)
        await loadScoring(model)
        model.setScore(8)
        let started = expectation(description: "Score request suspended")
        service.onUpdateStarted = { started.fulfill() }
        let settled = expectation(description: "Save rejects stale account acknowledgment")
        let token = model.$isSaving.dropFirst().filter { !$0 }.sink { _ in settled.fulfill() }
        model.save()
        await fulfillment(of: [started], timeout: 2)
        service.scoreIdentity = UUID()
        service.completeUpdate(with: .success(()))
        await fulfillment(of: [settled], timeout: 2)
        token.cancel()
        XCTAssertTrue(links.linkInvocations.isEmpty)
        XCTAssertNil(model.output)
        XCTAssertEqual(model.failure, .remoteUpdateExplanation(TrackerScoreEditingError.accountChanged.userMessage))
    }

    func testAccountSwitchWhileLocalLinkWaitsCannotCommitTheOldDraft() async {
        let service = scoringService()
        let links = TrackerLinkStoreFake()
        links.suspendsLinks = true
        let started = expectation(description: "Local link awaits commit")
        links.onLinkStarted = { started.fulfill() }
        let model = makeViewModel(service: service, links: links)
        await loadScoring(model)
        let settled = expectation(description: "Stale link rejected")
        let token = model.$isSaving.dropFirst().filter { !$0 }.sink { _ in settled.fulfill() }
        model.save()
        await fulfillment(of: [started], timeout: 2)
        service.scoreIdentity = UUID()
        links.completeLink(with: .success(()))
        await fulfillment(of: [settled], timeout: 2)
        token.cancel()
        XCTAssertNil(links.remoteMediaID(for: trackerTestDestination().mediaIdentity, providerID: "anilist"))
        XCTAssertFalse(model.isLocallyLinked)
        XCTAssertNil(model.output)
        XCTAssertEqual(model.failure, .remoteUpdateExplanation(TrackerScoreEditingError.accountChanged.userMessage))
    }

    func testAccountSwitchAfterLocalCommitRetainsTheDurableLinkWithoutReportingSaveSuccess() async {
        let service = scoringService()
        let links = TrackerLinkStoreFake()
        links.onLinkCommitted = { service.scoreIdentity = UUID() }
        let model = makeViewModel(service: service, links: links)
        await loadScoring(model)
        await saveScoring(model)
        XCTAssertEqual(links.remoteMediaID(for: trackerTestDestination().mediaIdentity, providerID: "anilist"), "remote-1")
        XCTAssertTrue(model.isLocallyLinked)
        XCTAssertNil(model.output)
        XCTAssertEqual(model.failure, .remoteUpdateExplanation(TrackerScoreEditingError.accountChanged.userMessage))
    }

    func testCancelledCurrentLoadDoesNotLeaveAnUnrecoverableSpinner() async {
        let service = scoringService()
        service.scoreFormatError = CancellationError()
        let model = makeViewModel(service: service)
        await loadScoring(model, state: .failure)
        XCTAssertNotNil(model.remoteLoadErrorMessage)
        XCTAssertFalse(model.isLoadingEntry)
    }

    private func scoringService() -> TrackerDetailsServiceFake {
        let service = TrackerDetailsServiceFake()
        service.scoreFormat = .point10Decimal
        service.queuedLoadResults = [.success(TrackerMediaEntry(
            status: "CURRENT", progress: 12, score: 7, startDate: nil, finishDate: nil
        ))]
        return service
    }

    private func loadScoring(
        _ model: TrackerDetailsViewModel,
        state: TrackerRemoteEntryPresentationState = .existing
    ) async {
        let loaded = expectation(description: "Remote score and entry loaded")
        let token = model.$remoteEntryState.filter { $0 == state }.sink { _ in loaded.fulfill() }
        model.start()
        await fulfillment(of: [loaded], timeout: 2)
        token.cancel()
    }

    private func saveScoring(_ model: TrackerDetailsViewModel) async {
        let saved = expectation(description: "Manual save settled")
        let token = model.$isSaving.dropFirst().filter { !$0 }.sink { _ in saved.fulfill() }
        model.save()
        await fulfillment(of: [saved], timeout: 2)
        token.cancel()
    }
}
